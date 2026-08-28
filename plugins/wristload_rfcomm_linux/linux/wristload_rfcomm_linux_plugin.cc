// Linux RFCOMM/SPP transport bridge for Wristload.
//
// Implements the same channel contract as the Android native bridge:
//   MethodChannel "wristload/rfcomm": ensurePermissions / pair / connect /
//     write / disconnect
//   EventChannel "wristload/rfcomm/events": binary packets plus
//     "rfcomm_closed" / "rfcomm_read" errors
//
// Transport stack: BlueZ on the system bus (org.bluez).
//   - Device resolution: ObjectManager.GetManagedObjects by Address.
//   - Pairing: org.bluez.AgentManager1 with a NoInputNoOutput agent that
//     auto-confirms authorization requests.
//   - SPP connect: org.bluez.ProfileManager1 registers a client Profile for
//     the requested service UUID; org.bluez.Device1.ConnectProfile lets BlueZ
//     resolve SDP and hand the connected socket to our NewConnection method.
//
// Threading: the GDBusConnection is created and the agent/profile objects are
// exported on the Flutter/GTK main thread, so inbound D-Bus calls (NewConnection,
// agent requests) are dispatched on the main loop. Pair/connect operations run
// on a worker thread using synchronous D-Bus calls; results are marshalled back
// to the main thread before any Flutter call is made. Data reads run on a
// dedicated reader thread.

#include "include/wristload_rfcomm_linux/wristload_rfcomm_linux_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>

#include <errno.h>
#include <fcntl.h>
#include <glib/gstdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define WRISTLOAD_RFCOMM_LINUX_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), wristload_rfcomm_linux_plugin_get_type(), \
                              WristloadRfcommLinuxPlugin))

#define BLUEZ_SERVICE "org.bluez"
#define BLUEZ_OBJECT "/org/bluez"
#define BLUEZ_AGENT_PATH "/wristload/agent"
#define BLUEZ_PROFILE_PATH "/wristload/profile"
#define DEFAULT_SPP_UUID "00001101-0000-1000-8000-00805f9b34fb"
#define PAIR_TIMEOUT_SECS 30
#define CONNECT_TIMEOUT_SECS 25
#define PAIR_POLL_MS 500

// State used to hand the NewConnection fd (delivered on the main thread) to
// the worker thread that issued ConnectProfile.
#define PENDING_FD_NONE -2
#define PENDING_FD_ABORTED -1

struct _WristloadRfcommLinuxPlugin {
  GObject parent_instance;

  GMainContext* main_context;  // Flutter/GTK main context (ref)
  FlEventChannel* events;      // "wristload/rfcomm/events"

  GMutex lock;                 // guards everything below
  gint generation;             // bumped per connect/disconnect
  gint fd;                     // active RFCOMM socket fd, -1 when closed
  GThread* reader;             // reader thread
  gboolean reader_alive;

  GCond fd_cond;               // signaled when pending_fd changes
  gint pending_fd;             // fd delivered by NewConnection

  GDBusConnection* bus;        // system bus connection (created on main thread)
  gboolean bus_ready;          // agent + profile exported and registered
  gchar* profile_uuid;         // UUID of the currently registered profile
  gchar* device_path;          // device object path of the current session
};

G_DEFINE_TYPE(WristloadRfcommLinuxPlugin, wristload_rfcomm_linux_plugin,
              g_object_get_type())

// --- BlueZ introspection data for exported objects -------------------------

static const gchar* kProfileIntrospectionXml =
    "<node>"
    "  <interface name='org.bluez.Profile1'>"
    "    <method name='Release'/>"
    "    <method name='NewConnection'>"
    "      <arg type='o' name='device' direction='in'/>"
    "      <arg type='h' name='fd' direction='in'/>"
    "      <arg type='a{sv}' name='properties' direction='in'/>"
    "    </method>"
    "    <method name='RequestDisconnection'>"
    "      <arg type='o' name='device' direction='in'/>"
    "    </method>"
    "  </interface>"
    "</node>";

static const gchar* kAgentIntrospectionXml =
    "<node>"
    "  <interface name='org.bluez.Agent1'>"
    "    <method name='Release'/>"
    "    <method name='RequestPinCode'>"
    "      <arg type='o' name='device' direction='in'/>"
    "      <arg type='s' name='pincode' direction='out'/>"
    "    </method>"
    "    <method name='DisplayPinCode'>"
    "      <arg type='o' name='device' direction='in'/>"
    "      <arg type='s' name='pincode' direction='in'/>"
    "    </method>"
    "    <method name='RequestPasskey'>"
    "      <arg type='o' name='device' direction='in'/>"
    "      <arg type='u' name='passkey' direction='out'/>"
    "    </method>"
    "    <method name='DisplayPasskey'>"
    "      <arg type='o' name='device' direction='in'/>"
    "      <arg type='u' name='passkey' direction='in'/>"
    "      <arg type='q' name='entered' direction='in'/>"
    "    </method>"
    "    <method name='RequestConfirmation'>"
    "      <arg type='o' name='device' direction='in'/>"
    "      <arg type='u' name='passkey' direction='in'/>"
    "    </method>"
    "    <method name='RequestAuthorization'>"
    "      <arg type='o' name='device' direction='in'/>"
    "    </method>"
    "    <method name='AuthorizeService'>"
    "      <arg type='o' name='device' direction='in'/>"
    "      <arg type='s' name='uuid' direction='in'/>"
    "    </method>"
    "    <method name='Cancel'/>"
    "  </interface>"
    "</node>";

// Process-lifetime GDBusNodeInfo instances; the interface info passed to
// g_dbus_connection_register_object must outlive the registration.
typedef struct {
  GDBusNodeInfo* profiles;
  GDBusNodeInfo* agents;
} BluezNodeInfos;

static BluezNodeInfos* ensure_node_infos(void) {
  static BluezNodeInfos infos = {NULL, NULL};
  if (infos.profiles == NULL) {
    GError* error = NULL;
    infos.profiles = g_dbus_node_info_new_for_xml(kProfileIntrospectionXml,
                                                  &error);
    g_clear_error(&error);
  }
  if (infos.agents == NULL) {
    GError* error = NULL;
    infos.agents = g_dbus_node_info_new_for_xml(kAgentIntrospectionXml,
                                                &error);
    g_clear_error(&error);
  }
  return &infos;
}

static void wristload_rfcomm_linux_plugin_dispose(GObject* object);
static void wristload_rfcomm_linux_plugin_finalize(GObject* object);

// --- Forward declarations --------------------------------------------------

static void bluez_profile_method_call(GDBusConnection* connection,
                                      const gchar* sender,
                                      const gchar* object_path,
                                      const gchar* interface_name,
                                      const gchar* method_name,
                                      GVariant* parameters,
                                      GDBusMethodInvocation* invocation,
                                      gpointer user_data);
static void bluez_agent_method_call(GDBusConnection* connection,
                                    const gchar* sender,
                                    const gchar* object_path,
                                    const gchar* interface_name,
                                    const gchar* method_name,
                                    GVariant* parameters,
                                    GDBusMethodInvocation* invocation,
                                    gpointer user_data);

static gboolean ensure_bus_and_export(WristloadRfcommLinuxPlugin* self,
                                      GError** error);
static gchar* resolve_device_path(WristloadRfcommLinuxPlugin* self,
                                  const gchar* address, GError** error);
static gboolean device_is_paired(WristloadRfcommLinuxPlugin* self,
                                 const gchar* device_path, GError** error);
static gboolean ensure_paired(WristloadRfcommLinuxPlugin* self,
                              const gchar* device_path, GError** error);
static gboolean register_profile(WristloadRfcommLinuxPlugin* self,
                                 const gchar* uuid, GError** error);
static gboolean unregister_profile(WristloadRfcommLinuxPlugin* self,
                                   GError** error);
static gboolean connect_profile(WristloadRfcommLinuxPlugin* self,
                                const gchar* device_path, const gchar* uuid,
                                GError** error);
static void close_current_socket(WristloadRfcommLinuxPlugin* self);
static void start_reader(WristloadRfcommLinuxPlugin* self, int fd);

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data);
static FlMethodErrorResponse* event_listen_cb(FlEventChannel* channel,
                                              FlValue* args,
                                              gpointer user_data);
static FlMethodErrorResponse* event_cancel_cb(FlEventChannel* channel,
                                              FlValue* args,
                                              gpointer user_data);

// --- GObject boilerplate ---------------------------------------------------

static void wristload_rfcomm_linux_plugin_dispose(GObject* object) {
  WristloadRfcommLinuxPlugin* self = WRISTLOAD_RFCOMM_LINUX_PLUGIN(object);

  g_mutex_lock(&self->lock);
  self->generation++;
  gint fd = self->fd;
  self->fd = -1;
  self->pending_fd = PENDING_FD_ABORTED;
  g_cond_broadcast(&self->fd_cond);
  gboolean stop_reader = self->reader_alive;
  self->reader_alive = FALSE;
  GThread* reader = self->reader;
  self->reader = NULL;
  GDBusConnection* bus = self->bus;
  self->bus = NULL;
  gchar* profile_uuid = self->profile_uuid;
  self->profile_uuid = NULL;
  gchar* device_path = self->device_path;
  self->device_path = NULL;
  g_mutex_unlock(&self->lock);

  if (stop_reader && fd >= 0) {
    shutdown(fd, SHUT_RDWR);
    g_close(fd, NULL);
  }
  if (reader != NULL) {
    // The reader thread exits promptly after the fd is shut down. Join it so
    // no GThread resources are leaked into the shutdown path.
    g_thread_join(reader);
  }
  if (profile_uuid != NULL) {
    unregister_profile(self, NULL);
  }
  g_free(profile_uuid);
  g_free(device_path);
  if (bus != NULL) g_object_unref(bus);

  g_clear_object(&self->events);
  if (self->main_context != NULL) g_main_context_unref(self->main_context);

  G_OBJECT_CLASS(wristload_rfcomm_linux_plugin_parent_class)->dispose(object);
}

static void wristload_rfcomm_linux_plugin_finalize(GObject* object) {
  WristloadRfcommLinuxPlugin* self = WRISTLOAD_RFCOMM_LINUX_PLUGIN(object);
  g_mutex_clear(&self->lock);
  g_cond_clear(&self->fd_cond);
  G_OBJECT_CLASS(wristload_rfcomm_linux_plugin_parent_class)->finalize(object);
}

static void wristload_rfcomm_linux_plugin_class_init(
    WristloadRfcommLinuxPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = wristload_rfcomm_linux_plugin_dispose;
  G_OBJECT_CLASS(klass)->finalize = wristload_rfcomm_linux_plugin_finalize;
}

static void wristload_rfcomm_linux_plugin_init(WristloadRfcommLinuxPlugin* self) {
  g_mutex_init(&self->lock);
  g_cond_init(&self->fd_cond);
  self->fd = -1;
  self->pending_fd = PENDING_FD_NONE;
  self->main_context = g_main_context_ref(g_main_context_default());
}

// --- Main-thread marshalling helper ----------------------------------------

typedef struct {
  WristloadRfcommLinuxPlugin* self;
  gboolean done;
  GError* error;
} BusInitOp;

static gboolean run_bus_init_on_main(BusInitOp* op) {
  WristloadRfcommLinuxPlugin* self = op->self;
  op->error = NULL;
  ensure_bus_and_export(self, &op->error);
  g_mutex_lock(&self->lock);
  op->done = TRUE;
  g_cond_signal(&self->fd_cond);
  g_mutex_unlock(&self->lock);
  return G_SOURCE_REMOVE;
}

// Runs ensure_bus_and_export on the Flutter/GTK main thread (a GDBusConnection
// must be created on the thread whose main context dispatches inbound calls).
static gboolean ensure_bus_on_main(WristloadRfcommLinuxPlugin* self,
                                   GError** error) {
  BusInitOp op;
  op.self = self;
  op.done = FALSE;
  op.error = NULL;
  g_main_context_invoke(self->main_context, (GSourceFunc)run_bus_init_on_main,
                        &op);
  g_mutex_lock(&self->lock);
  while (!op.done) {
    g_cond_wait(&self->fd_cond, &self->lock);
  }
  g_mutex_unlock(&self->lock);
  if (op.error != NULL) {
    *error = op.error;
    return FALSE;
  }
  return TRUE;
}

// --- BlueZ bus setup -------------------------------------------------------

static gboolean bluez_call(GDBusConnection* bus, const gchar* object_path,
                           const gchar* interface, const gchar* method,
                           GVariant* parameters, const GVariantType* reply_type,
                           GCancellable* cancellable, GVariant** reply,
                           GError** error) {
  // GLib >= 2.86: g_dbus_connection_call_sync() 不再接受 reply_out 参数，
  // 结果直接作为返回值返回。
  GVariant* result = g_dbus_connection_call_sync(
      bus, BLUEZ_SERVICE, object_path, interface, method, parameters,
      reply_type, G_DBUS_CALL_FLAGS_NONE, -1, cancellable, error);
  if (result == NULL) return FALSE;
  if (reply != NULL) {
    *reply = result;
  } else {
    g_variant_unref(result);
  }
  return TRUE;
}

static gboolean ensure_bus_and_export(WristloadRfcommLinuxPlugin* self,
                                      GError** error) {
  g_mutex_lock(&self->lock);
  if (self->bus_ready) {
    g_mutex_unlock(&self->lock);
    return TRUE;
  }
  g_mutex_unlock(&self->lock);

  if (self->bus == NULL) {
    self->bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, error);
    if (self->bus == NULL) {
      g_prefix_error(error, "BlueZ 系统总线不可用：");
      return FALSE;
    }
  }
  GDBusConnection* bus = self->bus;

  // Export the client profile object; BlueZ calls NewConnection on it with the
  // connected socket fd once ConnectProfile succeeds.
  GDBusInterfaceVTable profile_vtable;
  memset(&profile_vtable, 0, sizeof(profile_vtable));
  profile_vtable.method_call = bluez_profile_method_call;
  GError* local_error = NULL;
  guint profile_registration = g_dbus_connection_register_object(
      bus, BLUEZ_PROFILE_PATH, ensure_node_infos()->profiles->interfaces[0],
      &profile_vtable, self, nullptr, &local_error);
  if (profile_registration == 0) {
    g_propagate_error(error, local_error);
    g_prefix_error(error, "无法导出 BlueZ Profile 对象：");
    return FALSE;
  }

  // Export the pairing agent object.
  GDBusInterfaceVTable agent_vtable;
  memset(&agent_vtable, 0, sizeof(agent_vtable));
  agent_vtable.method_call = bluez_agent_method_call;
  local_error = NULL;
  guint agent_registration = g_dbus_connection_register_object(
      bus, BLUEZ_AGENT_PATH, ensure_node_infos()->agents->interfaces[0],
      &agent_vtable, self, nullptr, &local_error);
  if (agent_registration == 0) {
    g_propagate_error(error, local_error);
    g_prefix_error(error, "无法导出 BlueZ Agent 对象：");
    return FALSE;
  }

  // Register the profile manager entry for the default SPP UUID; the requested
  // service UUID is re-registered before each connect. A client-role profile
  // lets ConnectProfile resolve SDP and deliver the socket.
  //
  // GLib 2.88 的 g_variant_new 对 a{sv} 数组参数要求传 GVariantBuilder*
  // 指针（内部 end 并消费）；传 g_variant_new_array/builder_end 的结果
  // （GVariant*）会触发 fatal 断言导致进程崩溃。
  GVariantBuilder registerOptions;
  g_variant_builder_init(&registerOptions, G_VARIANT_TYPE("a{sv}"));
  local_error = NULL;
  gboolean ok = bluez_call(
      bus, BLUEZ_OBJECT, "org.bluez.ProfileManager1", "RegisterProfile",
      g_variant_new("(osa{sv})", BLUEZ_PROFILE_PATH, DEFAULT_SPP_UUID,
                    &registerOptions),
      G_VARIANT_TYPE("()"), NULL, NULL, &local_error);
  if (!ok) {
    // A leftover registration from a previous process may own the path; make
    // one best-effort UnregisterProfile attempt and retry.
    bluez_call(bus, BLUEZ_OBJECT, "org.bluez.ProfileManager1",
               "UnregisterProfile", g_variant_new("(o)", BLUEZ_PROFILE_PATH),
               G_VARIANT_TYPE("()"), NULL, NULL, NULL);
    g_clear_error(&local_error);
    GVariantBuilder retryOptions;
    g_variant_builder_init(&retryOptions, G_VARIANT_TYPE("a{sv}"));
    ok = bluez_call(
        bus, BLUEZ_OBJECT, "org.bluez.ProfileManager1", "RegisterProfile",
        g_variant_new("(osa{sv})", BLUEZ_PROFILE_PATH, DEFAULT_SPP_UUID,
                      &retryOptions),
        G_VARIANT_TYPE("()"), NULL, NULL, &local_error);
  }
  if (!ok) {
    g_propagate_error(error, local_error);
    g_prefix_error(error, "无法注册 BlueZ Profile：");
    return FALSE;
  }
  self->profile_uuid = g_strdup(DEFAULT_SPP_UUID);

  // Register the NoInputNoOutput pairing agent as the default agent.
  local_error = NULL;
  ok = bluez_call(bus, BLUEZ_OBJECT, "org.bluez.AgentManager1",
                  "RegisterAgent",
                  g_variant_new("(os)", BLUEZ_AGENT_PATH, "NoInputNoOutput"),
                  G_VARIANT_TYPE("()"), NULL, NULL, &local_error);
  if (ok) {
    bluez_call(bus, BLUEZ_OBJECT, "org.bluez.AgentManager1",
               "RequestDefaultAgent", g_variant_new("(o)", BLUEZ_AGENT_PATH),
               G_VARIANT_TYPE("()"), NULL, NULL, NULL);
  } else {
    g_clear_error(&local_error);
  }

  g_mutex_lock(&self->lock);
  self->bus_ready = TRUE;
  g_mutex_unlock(&self->lock);
  return TRUE;
}

// --- Exported org.bluez.Profile1 -------------------------------------------

// BlueZ calls NewConnection on our client profile once ConnectProfile has
// established the RFCOMM channel; the socket fd travels in the message fd list.
static void bluez_profile_method_call(GDBusConnection* connection,
                                      const gchar* sender,
                                      const gchar* object_path,
                                      const gchar* interface_name,
                                      const gchar* method_name,
                                      GVariant* parameters,
                                      GDBusMethodInvocation* invocation,
                                      gpointer user_data) {
  WristloadRfcommLinuxPlugin* self = WRISTLOAD_RFCOMM_LINUX_PLUGIN(user_data);

  if (g_strcmp0(method_name, "NewConnection") == 0) {
    const gchar* device = NULL;
    gint fd_index = -1;
    // 实测：g_variant_get 的 "(&o h a{sv})" 借用解包在本 GLib 构建会断言
    // （"is not a valid GVariant format string"），且第三参 NULL 跳过容器
    // 不被接受；改用 get_child_value 逐层取独立引用。
    GVariant* devicev = g_variant_get_child_value(parameters, 0);  // o
    GVariant* idxv = g_variant_get_child_value(parameters, 1);     // h
    if (devicev != NULL &&
        g_variant_is_of_type(devicev, G_VARIANT_TYPE_OBJECT_PATH)) {
      device = g_variant_get_string(devicev, NULL);
    }
    if (idxv != NULL && g_variant_is_of_type(idxv, G_VARIANT_TYPE_HANDLE)) {
      // h 是 HANDLE 类型（非 INT32），必须用 g_variant_get_handle，否则
      // g_variant_get_int32 会断言失败。
      fd_index = g_variant_get_handle(idxv);
    }
    if (devicev != NULL) g_variant_unref(devicev);
    if (idxv != NULL) g_variant_unref(idxv);
    GDBusMessage* message = g_dbus_method_invocation_get_message(invocation);
    GUnixFDList* fd_list = g_dbus_message_get_unix_fd_list(message);
    GError* error = NULL;
    int fd = -1;
    if (fd_list != NULL && fd_index >= 0) {
      fd = g_unix_fd_list_get(fd_list, fd_index, &error);
    }
    if (fd < 0) {
      g_dbus_method_invocation_return_error(
          invocation, G_DBUS_ERROR, G_DBUS_ERROR_FAILED,
          "BlueZ 未提供 RFCOMM 连接描述符：%s",
          error != NULL ? error->message : "fd list unavailable");
      g_clear_error(&error);
      return;
    }
    g_mutex_lock(&self->lock);
    if (self->pending_fd == PENDING_FD_ABORTED) {
      // A disconnect superseded the connection that owns this socket.
      g_mutex_unlock(&self->lock);
      g_close(fd, NULL);
      g_dbus_method_invocation_return_value(invocation, NULL);
      return;
    }
    if (self->fd >= 0) {
      // A previous session still owns an fd; never leak it into a new one.
      gint old_fd = self->fd;
      self->fd = -1;
      g_mutex_unlock(&self->lock);
      g_close(old_fd, NULL);
      g_mutex_lock(&self->lock);
      g_message("wristload: NewConnection 替换旧 fd old=%d new=%d", old_fd, fd);
    }
    self->pending_fd = fd;
    g_cond_broadcast(&self->fd_cond);
    g_mutex_unlock(&self->lock);
    // 日志放在真正交付（设置 pending_fd）之后，避免 ABORTED 分支误报交付。
    g_message("wristload: NewConnection 交付 fd=%d device=%s", fd, device);
    g_dbus_method_invocation_return_value(invocation, NULL);
    return;
  }

  if (g_strcmp0(method_name, "RequestDisconnection") == 0) {
    g_dbus_method_invocation_return_value(invocation, NULL);
    return;
  }

  // Release: the profile is being removed by BlueZ.
  g_dbus_method_invocation_return_value(invocation, NULL);
}

// --- Exported org.bluez.Agent1 ---------------------------------------------

// NoInputNoOutput agent: cannot type PINs or passkeys; authorization requests
// are auto-confirmed so bonding proceeds without a system dialog.
static void bluez_agent_method_call(GDBusConnection* connection,
                                    const gchar* sender,
                                    const gchar* object_path,
                                    const gchar* interface_name,
                                    const gchar* method_name,
                                    GVariant* parameters,
                                    GDBusMethodInvocation* invocation,
                                    gpointer user_data) {
  if (g_strcmp0(method_name, "RequestPinCode") == 0 ||
      g_strcmp0(method_name, "RequestPasskey") == 0) {
    g_dbus_method_invocation_return_dbus_error(
        invocation, "org.bluez.Error.Rejected", "Pin or passkey entry is not supported");
    return;
  }
  // RequestConfirmation / RequestAuthorization / AuthorizeService / Cancel /
  // DisplayPinCode / DisplayPasskey / Release: accept.
  g_dbus_method_invocation_return_value(invocation, NULL);
}

// --- Device resolution -----------------------------------------------------

static gchar* resolve_device_path(WristloadRfcommLinuxPlugin* self,
                                  const gchar* address, GError** error) {
  g_autofree gchar* normalized = g_ascii_strup(address, -1);
  GVariant* reply = NULL;
  // GetManagedObjects 单返回值经 GDBus 包装为元组 (a{oa{sa{sv}}})，child 0
  // 是完整对象表。实测确认：g_variant_get/iter_next 的借用解包在本场景
  // 返回空容器（ifaces 为 0 子值），必须用 g_variant_get_child_value 逐层
  // 取独立引用（每个都需 unref）。
  if (!bluez_call(self->bus, "/", "org.freedesktop.DBus.ObjectManager",
                  "GetManagedObjects", NULL, G_VARIANT_TYPE("(a{oa{sa{sv}}})"),
                  NULL, &reply, error)) {
    g_prefix_error(error, "无法枚举 BlueZ 设备：");
    return NULL;
  }
  GVariant* objects = g_variant_get_child_value(reply, 0);
  gchar* found = NULL;
  const gsize n = g_variant_n_children(objects);
  for (gsize i = 0; i < n && found == NULL; i++) {
    GVariant* entry = g_variant_get_child_value(objects, i);     // {oa{sa{sv}}}
    GVariant* pathv = g_variant_get_child_value(entry, 0);       // o
    GVariant* interfaces = g_variant_get_child_value(entry, 1);  // a{sa{sv}}
    const gchar* path = g_variant_get_string(pathv, NULL);
    const gsize ni = g_variant_n_children(interfaces);
    for (gsize j = 0; j < ni && found == NULL; j++) {
      GVariant* ientry = g_variant_get_child_value(interfaces, j);  // {sa{sv}}
      GVariant* ifacev = g_variant_get_child_value(ientry, 0);      // s
      GVariant* props = g_variant_get_child_value(ientry, 1);       // a{sv}
      const gchar* iface = g_variant_get_string(ifacev, NULL);
      if (g_strcmp0(iface, "org.bluez.Device1") == 0) {
        const gsize np = g_variant_n_children(props);
        for (gsize k = 0; k < np && found == NULL; k++) {
          GVariant* pentry = g_variant_get_child_value(props, k);   // {sv}
          GVariant* keyv = g_variant_get_child_value(pentry, 0);    // s
          GVariant* valv = g_variant_get_child_value(pentry, 1);    // v
          const gchar* key = g_variant_get_string(keyv, NULL);
          if (g_strcmp0(key, "Address") == 0) {
            GVariant* inner = g_variant_get_variant(valv);          // 解包 v
            if (inner != NULL &&
                g_variant_is_of_type(inner, G_VARIANT_TYPE_STRING)) {
              const gchar* addr = g_variant_get_string(inner, NULL);
              if (addr != NULL &&
                  g_ascii_strcasecmp(addr, normalized) == 0) {
                found = g_strdup(path);
              }
            }
            if (inner != NULL) g_variant_unref(inner);
          }
          g_variant_unref(keyv);
          g_variant_unref(valv);
          g_variant_unref(pentry);
        }
      }
      g_variant_unref(ifacev);
      g_variant_unref(props);
      g_variant_unref(ientry);
    }
    g_variant_unref(pathv);
    g_variant_unref(interfaces);
    g_variant_unref(entry);
  }
  g_variant_unref(objects);
  g_variant_unref(reply);
  if (found == NULL) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
                "未找到地址为 %s 的蓝牙设备（请先完成 BLE 扫描）", address);
  }
  return found;
}

// 在 ObjectManager 中查找适配器对象路径（org.bluez.Adapter1）。
static gchar* find_adapter_path(WristloadRfcommLinuxPlugin* self,
                                GError** error) {
  GVariant* reply = NULL;
  // 与 resolve_device_path 同理：reply 是元组 (a{oa{sa{sv}}})，child 0 是
  // 完整对象表；必须用 get_child_value 逐层取独立引用（实测借用解包失效）。
  if (!bluez_call(self->bus, "/", "org.freedesktop.DBus.ObjectManager",
                  "GetManagedObjects", NULL, G_VARIANT_TYPE("(a{oa{sa{sv}}})"),
                  NULL, &reply, error)) {
    g_prefix_error(error, "无法枚举 BlueZ 适配器：");
    return NULL;
  }
  GVariant* objects = g_variant_get_child_value(reply, 0);
  gchar* found = NULL;
  const gsize n = g_variant_n_children(objects);
  for (gsize i = 0; i < n && found == NULL; i++) {
    GVariant* entry = g_variant_get_child_value(objects, i);
    GVariant* pathv = g_variant_get_child_value(entry, 0);
    GVariant* interfaces = g_variant_get_child_value(entry, 1);
    const gchar* path = g_variant_get_string(pathv, NULL);
    const gsize ni = g_variant_n_children(interfaces);
    for (gsize j = 0; j < ni && found == NULL; j++) {
      GVariant* ientry = g_variant_get_child_value(interfaces, j);
      GVariant* ifacev = g_variant_get_child_value(ientry, 0);
      const gchar* iface = g_variant_get_string(ifacev, NULL);
      if (g_strcmp0(iface, "org.bluez.Adapter1") == 0) {
        found = g_strdup(path);
      }
      g_variant_unref(ifacev);
      g_variant_unref(ientry);
    }
    g_variant_unref(pathv);
    g_variant_unref(interfaces);
    g_variant_unref(entry);
  }
  g_variant_unref(objects);
  g_variant_unref(reply);
  if (found == NULL) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
                "未找到蓝牙适配器（org.bluez.Adapter1）");
  }
  return found;
}

// BlueZ 会在 discovery 结束后移除未配对（临时）设备的对象。扫描已停止时
// pair/connect 会找不到设备（GetManagedObjects 无对应对象），这里自动
// 短暂重启 discovery 等待设备重新出现，再停止 discovery。
static gchar* resolve_device_path_with_rescan(WristloadRfcommLinuxPlugin* self,
                                              const gchar* address,
                                              GError** error) {
  GError* local_error = NULL;
  gchar* found = resolve_device_path(self, address, &local_error);
  if (found != NULL) {
    g_message("wristload: resolve 直接命中 %s", address);
    g_clear_error(&local_error);
    return found;
  }
  g_message("wristload: resolve 未命中 %s（%s），进入重扫", address,
            local_error != NULL ? local_error->message : "无错误信息");
  g_clear_error(&local_error);

  gchar* adapter = find_adapter_path(self, &local_error);
  if (adapter == NULL) {
    if (local_error == NULL) {
      g_set_error(&local_error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
                  "未找到蓝牙适配器（org.bluez.Adapter1）");
    }
    g_propagate_error(error, local_error);
    g_prefix_error(error, "无法定位蓝牙适配器：");
    return NULL;
  }
  // StartDiscovery 已在进行时返回 org.bluez.Error.AlreadyExists，忽略即可；
  // StopDiscovery 同理（No discovery started 时忽略）。
  bluez_call(self->bus, adapter, "org.bluez.Adapter1", "StartDiscovery",
             NULL, G_VARIANT_TYPE("()"), NULL, NULL, NULL);
  for (int i = 0; i < 16 && found == NULL; i++) {
    g_usleep(500 * 1000);
    found = resolve_device_path(self, address, NULL);
  }
  bluez_call(self->bus, adapter, "org.bluez.Adapter1", "StopDiscovery",
             NULL, G_VARIANT_TYPE("()"), NULL, NULL, NULL);
  g_free(adapter);
  if (found == NULL) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
                "未找到地址为 %s 的蓝牙设备（重新发现 8 秒超时）", address);
  }
  return found;
}

static gboolean device_is_paired(WristloadRfcommLinuxPlugin* self,
                                 const gchar* device_path, GError** error) {
  GVariant* reply = NULL;
  // Properties.Get 单返回值（裸 v）经 GDBus 包装为元组 (v)；同样用
  // get_child_value 取独立引用（实测借用解包失效）。
  if (!bluez_call(self->bus, device_path, "org.freedesktop.DBus.Properties",
                  "Get", g_variant_new("(ss)", "org.bluez.Device1", "Paired"),
                  G_VARIANT_TYPE("(v)"), NULL, &reply, error)) {
    return FALSE;
  }
  GVariant* value = g_variant_get_child_value(reply, 0);  // v 包装
  GVariant* inner = value != NULL ? g_variant_get_variant(value) : NULL;
  gboolean paired =
      inner != NULL && g_variant_is_of_type(inner, G_VARIANT_TYPE_BOOLEAN)
          ? g_variant_get_boolean(inner)
          : FALSE;
  if (inner != NULL) g_variant_unref(inner);
  if (value != NULL) g_variant_unref(value);
  g_variant_unref(reply);
  return paired;
}

// --- Pairing ---------------------------------------------------------------

static gboolean arm_cancel_timeout_cb(gpointer data) {
  GCancellable* cancellable = static_cast<GCancellable*>(data);
  g_timeout_add_seconds_full(G_PRIORITY_DEFAULT, PAIR_TIMEOUT_SECS,
                             [](gpointer d) -> gboolean {
                               g_cancellable_cancel(static_cast<GCancellable*>(d));
                               return G_SOURCE_REMOVE;
                             },
                             g_object_ref(cancellable), g_object_unref);
  g_object_unref(cancellable);
  return G_SOURCE_REMOVE;
}

// Pairs the device when it is not bonded yet. Requires the system BlueZ
// pairing agent; PIN entry flows are rejected by design.
static gboolean ensure_paired(WristloadRfcommLinuxPlugin* self,
                              const gchar* device_path, GError** error) {
  GError* local_error = NULL;
  if (device_is_paired(self, device_path, &local_error)) {
    // 已有 bond：确保 Trusted（已配对设备免模式直连的主机侧前提）。
    GError* trust_err = NULL;
    bluez_call(self->bus, device_path, "org.freedesktop.DBus.Properties", "Set",
               g_variant_new("(ssv)", "org.bluez.Device1", "Trusted",
                             g_variant_new_boolean(TRUE)),
               G_VARIANT_TYPE("()"), NULL, NULL, &trust_err);
    g_clear_error(&trust_err);
    return TRUE;
  }
  if (local_error != NULL) {
    g_propagate_error(error, local_error);
    return FALSE;
  }

  // 小米手环 9 的绑定通常需要用户在手表或系统配对 UI 上确认；
  // NoInputNoOutput 代理自动确认后 bond 可能未持久化（实测 Paired 回落为
  // no，RFCOMM 连接被设备立即关闭）。失败时给出明确的系统配对引导。
  g_autoptr(GCancellable) cancellable = g_cancellable_new();
  g_main_context_invoke(self->main_context, arm_cancel_timeout_cb,
                        g_object_ref(cancellable));
  local_error = NULL;
  gboolean ok = bluez_call(self->bus, device_path, "org.bluez.Device1", "Pair",
                           NULL, G_VARIANT_TYPE("()"), cancellable, NULL,
                           &local_error);
  g_cancellable_cancel(cancellable);
  if (!ok) {
    g_propagate_error(error, local_error);
    g_prefix_error(
        error,
        "经典蓝牙配对失败：请先在系统蓝牙设置中完成配对（bluetoothctl pair 或桌面蓝牙设置），再重试连接。");
    return FALSE;
  }

  // 要求 Paired 属性稳定为 true（连续两次查询，间隔 500ms），避免 bond 被
  // 设备端拒绝后“短暂为 true 再回落”被误判为配对成功。
  const int polls = (PAIR_TIMEOUT_SECS * 1000) / PAIR_POLL_MS;
  gboolean stable = FALSE;
  for (int i = 0; i < polls; i++) {
    g_clear_error(&local_error);
    const gboolean paired = device_is_paired(self, device_path, &local_error);
    if (local_error != NULL) {
      g_propagate_error(error, local_error);
      return FALSE;
    }
    if (paired) {
      if (stable) {
        // bond 稳定：设置 Trusted（免模式直连的前提）。
        GError* trust_err = NULL;
        bluez_call(self->bus, device_path, "org.freedesktop.DBus.Properties",
                   "Set",
                   g_variant_new("(ssv)", "org.bluez.Device1", "Trusted",
                                 g_variant_new_boolean(TRUE)),
                   G_VARIANT_TYPE("()"), NULL, NULL, &trust_err);
        g_clear_error(&trust_err);
        return TRUE;
      }
      stable = TRUE;
    } else {
      stable = FALSE;
    }
    g_usleep(PAIR_POLL_MS * 1000);
  }
  g_set_error(error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
              "蓝牙配对未完成（%d 秒超时）：请先在系统蓝牙设置中完成配对"
              "（bluetoothctl pair 或桌面蓝牙设置），再重试连接。",
              PAIR_TIMEOUT_SECS);
  return FALSE;
}

// --- Profile registration --------------------------------------------------

static gboolean register_profile(WristloadRfcommLinuxPlugin* self,
                                 const gchar* uuid, GError** error) {
  g_mutex_lock(&self->lock);
  gboolean same =
      self->profile_uuid != NULL && g_strcmp0(self->profile_uuid, uuid) == 0;
  g_mutex_unlock(&self->lock);
  if (same) return TRUE;

  unregister_profile(self, NULL);
  g_autoptr(GVariantBuilder) builder =
      g_variant_builder_new(G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(builder, "{sv}", "Role",
                        g_variant_new_string("client"));
  GError* local_error = NULL;
  gboolean ok = bluez_call(
      self->bus, BLUEZ_OBJECT, "org.bluez.ProfileManager1", "RegisterProfile",
      // 传 builder 指针；g_variant_new 内部 end 并消费（GLib 2.88 要求）。
      g_variant_new("(osa{sv})", BLUEZ_PROFILE_PATH, uuid, builder),
      G_VARIANT_TYPE("()"), NULL, NULL, &local_error);
  if (!ok) {
    g_propagate_error(error, local_error);
    g_prefix_error(error, "无法注册服务 UUID %s 的 Profile：", uuid);
    return FALSE;
  }
  g_mutex_lock(&self->lock);
  g_free(self->profile_uuid);
  self->profile_uuid = g_strdup(uuid);
  g_mutex_unlock(&self->lock);
  return TRUE;
}

static gboolean unregister_profile(WristloadRfcommLinuxPlugin* self,
                                   GError** error) {
  g_mutex_lock(&self->lock);
  gchar* current = self->profile_uuid;
  self->profile_uuid = NULL;
  GDBusConnection* bus = self->bus;
  g_mutex_unlock(&self->lock);
  if (current == NULL || bus == NULL) {
    g_free(current);
    return TRUE;
  }
  gboolean ok = bluez_call(bus, BLUEZ_OBJECT, "org.bluez.ProfileManager1",
                           "UnregisterProfile",
                           g_variant_new("(o)", BLUEZ_PROFILE_PATH),
                           G_VARIANT_TYPE("()"), NULL, NULL, error);
  g_free(current);
  return ok;
}

// --- ConnectProfile --------------------------------------------------------

static gboolean connect_profile(WristloadRfcommLinuxPlugin* self,
                                const gchar* device_path, const gchar* uuid,
                                GError** error) {
  g_autoptr(GCancellable) cancellable = g_cancellable_new();
  g_main_context_invoke(self->main_context, arm_cancel_timeout_cb,
                        g_object_ref(cancellable));
  // 清除上一次连接/断开残留的 pending_fd（可能为 ABORTED 或旧 fd）：
  // 残留 ABORTED 会让 NewConnection 丢弃新 fd（假超时），残留旧 fd 会
  // 串线到新连接。
  g_mutex_lock(&self->lock);
  self->pending_fd = PENDING_FD_NONE;
  g_mutex_unlock(&self->lock);
  GError* local_error = NULL;
  gboolean ok = bluez_call(self->bus, device_path, "org.bluez.Device1",
                           "ConnectProfile", g_variant_new("(s)", uuid),
                           G_VARIANT_TYPE("()"), cancellable, NULL,
                           &local_error);
  if (!ok) {
    // 已配对设备免模式直连：ConnectProfile 被设备拒绝（如
    // br-connection-refused，设备未处于“连接新手机”模式）时，先尝试
    // Device1.Connect 建立 ACL 链路（bonded 设备通常放行链路层连接），
    // 短暂等待后重试一次 ConnectProfile。仍失败则走原有错误路径。
    g_message("wristload: ConnectProfile 失败（%s），尝试 Connect 建立 ACL 链路后重试",
              local_error != NULL ? local_error->message : "unknown");
    GError* connect_err = NULL;
    bluez_call(self->bus, device_path, "org.bluez.Device1", "Connect",
               NULL, G_VARIANT_TYPE("()"), NULL, NULL, &connect_err);
    g_clear_error(&connect_err);
    g_usleep(500 * 1000);
    g_clear_error(&local_error);
    ok = bluez_call(self->bus, device_path, "org.bluez.Device1",
                    "ConnectProfile", g_variant_new("(s)", uuid),
                    G_VARIANT_TYPE("()"), cancellable, NULL, &local_error);
  }
  g_cancellable_cancel(cancellable);

  g_mutex_lock(&self->lock);
  gint fd = self->pending_fd;
  if (fd == PENDING_FD_NONE && ok) {
    gint64 deadline =
        g_get_monotonic_time() + CONNECT_TIMEOUT_SECS * G_TIME_SPAN_SECOND;
    while (self->pending_fd == PENDING_FD_NONE) {
      if (!g_cond_wait_until(&self->fd_cond, &self->lock, deadline)) break;
    }
    fd = self->pending_fd;
  }
  if (fd != PENDING_FD_NONE && fd != PENDING_FD_ABORTED) {
    self->pending_fd = PENDING_FD_NONE;
  }
  g_mutex_unlock(&self->lock);

  if (!ok) {
    if (fd > 0) g_close(fd, NULL);
    g_propagate_error(error, local_error);
    g_prefix_error(error, "SPP 服务连接失败：");
    return FALSE;
  }
  if (fd < 0) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
                "等待 RFCOMM 连接超时（%d 秒）", CONNECT_TIMEOUT_SECS);
    return FALSE;
  }
  g_mutex_lock(&self->lock);
  self->fd = fd;
  g_mutex_unlock(&self->lock);
  g_message("wristload: connect_profile 设置 self->fd=%d", fd);
  return TRUE;
}

// --- Socket lifecycle ------------------------------------------------------

static void close_current_socket(WristloadRfcommLinuxPlugin* self) {
  g_mutex_lock(&self->lock);
  self->generation++;
  gint fd = self->fd;
  self->fd = -1;
  self->pending_fd = PENDING_FD_ABORTED;
  g_cond_broadcast(&self->fd_cond);
  GThread* reader = self->reader;
  self->reader = NULL;
  gboolean reader_alive = self->reader_alive;
  self->reader_alive = FALSE;
  g_mutex_unlock(&self->lock);

  if (fd >= 0) {
    // shutdown() interrupts a blocked read() so the reader thread can exit.
    shutdown(fd, SHUT_RDWR);
    g_close(fd, NULL);
  }
  // Join even when the reader already exited on its own (device closed the
  // channel): g_thread_join releases the GThread resources in both cases.
  // Joining a reader that exited naturally is safe and happens at most once
  // per thread because self->reader was cleared above.
  if (reader != NULL && reader_alive) {
    g_thread_join(reader);
  }
}

typedef struct {
  WristloadRfcommLinuxPlugin* self;
  int fd;
} ReaderContext;

typedef struct {
  WristloadRfcommLinuxPlugin* self;
  FlEventChannel* events;  // ref'd; NULL when the channel is gone
  gchar* data;
  gsize len;
  gboolean is_error;
  gchar* error_code;
  gchar* error_message;
} ReaderEvent;

// Runs on the Flutter/GTK main thread; posts the packet to the Dart side.
static gboolean dispatch_reader_event(ReaderEvent* event) {
  FlEventChannel* events = event->events;
  if (events != NULL) {
    if (event->is_error) {
      fl_event_channel_send_error(events, event->error_code,
                                  event->error_message, nullptr, nullptr,
                                  nullptr);
    } else if (event->len > 0) {
      g_autoptr(FlValue) value =
          fl_value_new_uint8_list(reinterpret_cast<const uint8_t*>(event->data),
                                  event->len);
      fl_event_channel_send(events, value, nullptr, nullptr);
    }
  }
  g_clear_object(&event->events);
  g_free(event->data);
  g_free(event->error_code);
  g_free(event->error_message);
  g_free(event);
  return G_SOURCE_REMOVE;
}

// Reads packets from the RFCOMM socket and posts them to the main thread.
// g_idle_add is used instead of g_main_context_invoke so the reader thread
// never blocks on the main loop (which would deadlock a main-thread join).
static gpointer reader_thread(gpointer data) {
  ReaderContext* ctx = static_cast<ReaderContext*>(data);
  WristloadRfcommLinuxPlugin* self = ctx->self;
  int fd = ctx->fd;
  g_free(ctx);

  gchar buffer[4096];
  ssize_t exit_count = -999;
  int exit_errno_value = 0;
  for (;;) {
    ssize_t count = read(fd, buffer, sizeof(buffer));
    if (count > 0) {
      ReaderEvent* event = g_new0(ReaderEvent, 1);
      event->events = self->events != NULL ? g_object_ref(self->events) : NULL;
      event->data = static_cast<gchar*>(g_malloc(count));
      memcpy(event->data, buffer, count);
      event->len = count;
      g_idle_add(reinterpret_cast<GSourceFunc>(dispatch_reader_event), event);
      continue;
    }
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      // BlueZ 交付的 fd 可能是非阻塞的；连接刚建立、设备尚未发数据时
      // read 会返回 EAGAIN。此时连接仍然有效，绝不能关闭 fd（否则后续
      // 写入会报 “RFCOMM not connected”）。短暂等待后继续读。
      g_usleep(20 * 1000);
      continue;
    }
    exit_count = count;
    exit_errno_value = errno;
    ReaderEvent* event = g_new0(ReaderEvent, 1);
    event->events = self->events != NULL ? g_object_ref(self->events) : NULL;
    event->is_error = TRUE;
    if (count == 0) {
      event->error_code = g_strdup("rfcomm_closed");
      event->error_message = g_strdup("RFCOMM closed");
    } else {
      event->error_code = g_strdup("rfcomm_read");
      event->error_message = g_strdup(g_strerror(errno));
    }
    g_idle_add(reinterpret_cast<GSourceFunc>(dispatch_reader_event), event);
    break;
  }

  g_mutex_lock(&self->lock);
  self->reader_alive = FALSE;
  if (self->fd == fd) self->fd = -1;
  g_mutex_unlock(&self->lock);
  g_message("wristload: reader 退出 fd=%d count=%zd errno=%d(%s)", fd,
            exit_count, exit_errno_value,
            exit_count < 0 ? g_strerror(exit_errno_value) : "");
  return NULL;
}

static void start_reader(WristloadRfcommLinuxPlugin* self, int fd) {
  g_message("wristload: start_reader fd=%d", fd);
  // BlueZ 通过 NewConnection 交付的 socket fd 可能是非阻塞的。清除
  // O_NONBLOCK 让 reader 的 read 阻塞等待设备数据（与 read 循环里的
  // EAGAIN 分支构成双保险），避免连接刚建立、设备尚未发数据时被误判为
  // 断开并关闭 fd。
  const gint fd_flags = fcntl(fd, F_GETFL, 0);
  if (fd_flags >= 0) {
    fcntl(fd, F_SETFL, fd_flags & ~O_NONBLOCK);
  }
  g_mutex_lock(&self->lock);
  GThread* old_reader = self->reader;
  self->reader = NULL;
  gboolean had_old = old_reader != NULL;
  g_mutex_unlock(&self->lock);

  if (had_old) {
    // A previous reader either exited by itself (device closed the channel)
    // or was stopped by a replaced fd. Join it so the GThread resources are
    // released before the new session starts; the join returns immediately
    // when the thread already terminated.
    g_thread_join(old_reader);
  }

  g_mutex_lock(&self->lock);
  self->reader_alive = TRUE;
  ReaderContext* ctx = g_new0(ReaderContext, 1);
  ctx->self = self;
  ctx->fd = fd;
  self->reader = g_thread_new("wristload-rfcomm-reader", reader_thread, ctx);
  g_mutex_unlock(&self->lock);
}

// --- Method handlers -------------------------------------------------------

typedef struct {
  WristloadRfcommLinuxPlugin* self;
  FlMethodCall* call;
  GError* error;    // NULL means success
  FlValue* result;  // optional success payload
} Reply;

static gboolean deliver_reply(Reply* reply) {
  if (reply->error != NULL) {
    fl_method_call_respond_error(reply->call, "rfcomm_operation",
                                 reply->error->message, nullptr, nullptr);
  } else {
    fl_method_call_respond_success(reply->call, reply->result, nullptr);
  }
  if (reply->error != NULL) g_error_free(reply->error);
  if (reply->result != NULL) g_object_unref(reply->result);
  g_object_unref(reply->call);
  g_free(reply);
  return G_SOURCE_REMOVE;
}

typedef struct {
  WristloadRfcommLinuxPlugin* self;
  FlMethodCall* call;
  gchar* address;
  gchar* service_uuid;  // NULL for pair
} Op;

static gpointer pair_worker(gpointer data) {
  Op* op = static_cast<Op*>(data);
  Reply* reply = g_new0(Reply, 1);
  reply->self = op->self;
  reply->call = op->call;
  GError* error = NULL;

  if (!ensure_bus_on_main(op->self, &error)) {
    reply->error = error;
  } else {
    gchar* device_path =
        resolve_device_path_with_rescan(op->self, op->address, &error);
    if (device_path == NULL && error == NULL) {
      // 防御：内部路径异常（如 g_propagate_error 未传播）时绝不“假成功”，
      // 否则 Dart 侧会以为 RFCOMM 已连接并直接发送协议帧。
      g_set_error(&error, G_IO_ERROR, G_IO_ERROR_FAILED,
                  "无法定位设备 %s（BlueZ 对象不可用）", op->address);
    }
    if (device_path != NULL) {
      if (ensure_paired(op->self, device_path, &error)) {
        g_mutex_lock(&op->self->lock);
        g_free(op->self->device_path);
        op->self->device_path = g_strdup(device_path);
        g_mutex_unlock(&op->self->lock);
      }
      g_free(device_path);
    }
  }
  reply->error = error;
  g_main_context_invoke(op->self->main_context,
                        reinterpret_cast<GSourceFunc>(deliver_reply), reply);
  g_free(op->address);
  g_free(op->service_uuid);
  g_free(op);
  return NULL;
}

static gpointer connect_worker(gpointer data) {
  Op* op = static_cast<Op*>(data);
  Reply* reply = g_new0(Reply, 1);
  reply->self = op->self;
  reply->call = op->call;
  GError* error = NULL;

  const gchar* uuid =
      op->service_uuid != NULL ? op->service_uuid : DEFAULT_SPP_UUID;
  if (!ensure_bus_on_main(op->self, &error)) {
    reply->error = error;
  } else {
    gchar* device_path =
        resolve_device_path_with_rescan(op->self, op->address, &error);
    if (device_path == NULL && error == NULL) {
      // 防御：内部路径异常（如 g_propagate_error 未传播）时绝不“假成功”，
      // 否则 Dart 侧会以为 RFCOMM 已连接并直接发送协议帧。
      g_set_error(&error, G_IO_ERROR, G_IO_ERROR_FAILED,
                  "无法定位设备 %s（BlueZ 对象不可用）", op->address);
    }
    if (device_path != NULL) {
      gboolean ok = ensure_paired(op->self, device_path, &error);
      if (ok) ok = register_profile(op->self, uuid, &error);
      if (ok) ok = connect_profile(op->self, device_path, uuid, &error);
      if (ok) {
        g_mutex_lock(&op->self->lock);
        g_free(op->self->device_path);
        op->self->device_path = g_strdup(device_path);
        gint fd = op->self->fd;
        g_mutex_unlock(&op->self->lock);
        if (fd >= 0) start_reader(op->self, fd);
      }
      g_free(device_path);
    }
  }
  reply->error = error;
  g_main_context_invoke(op->self->main_context,
                        reinterpret_cast<GSourceFunc>(deliver_reply), reply);
  g_free(op->address);
  g_free(op->service_uuid);
  g_free(op);
  return NULL;
}

static void spawn_worker(WristloadRfcommLinuxPlugin* self,
                         FlMethodCall* call, gboolean is_pair) {
  FlValue* args = fl_method_call_get_args(call);
  Op* op = g_new0(Op, 1);
  op->self = self;
  op->call = g_object_ref(call);
  // Dart 侧 pair 传裸地址字符串，connect 传 {'address':…, 'serviceUuid':…}。
  // 必须先确认类型是 MAP 才能调用 fl_value_lookup_string：flutter_linux 的
  // fl_value_lookup 对非 MAP 值会触发断言（critical），曾导致连接时进程
  // 崩溃（日志只见“经典蓝牙配对请求”后无任何输出）。
  const gchar* address = NULL;
  if (args != NULL && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* addressValue = fl_value_lookup_string(args, "address");
    if (addressValue != NULL &&
        fl_value_get_type(addressValue) == FL_VALUE_TYPE_STRING) {
      address = fl_value_get_string(addressValue);
    }
  } else if (args != NULL &&
             fl_value_get_type(args) == FL_VALUE_TYPE_STRING) {
    address = fl_value_get_string(args);
  }
  if (address == NULL || address[0] == '\0') {
    fl_method_call_respond_error(
        call, "rfcomm_invalid_arguments",
        is_pair ? "pair 需要设备地址" : "connect 需要设备地址", nullptr,
        nullptr);
    g_free(op);
    return;
  }
  op->address = g_strdup(address);
  if (!is_pair && args != NULL && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* service = fl_value_lookup_string(args, "serviceUuid");
    if (service != NULL &&
        fl_value_get_type(service) == FL_VALUE_TYPE_STRING) {
      op->service_uuid = g_strdup(fl_value_get_string(service));
    }
  }
  g_thread_new(is_pair ? "wristload-rfcomm-pair" : "wristload-rfcomm-connect",
               is_pair ? pair_worker : connect_worker, op);
}

static void handle_write(WristloadRfcommLinuxPlugin* self,
                         FlMethodCall* call) {
  FlValue* args = fl_method_call_get_args(call);
  if (args == NULL || fl_value_get_type(args) != FL_VALUE_TYPE_UINT8_LIST) {
    fl_method_call_respond_error(call, "rfcomm_invalid_arguments",
                                 "write 需要二进制数据", nullptr, nullptr);
    return;
  }
  g_mutex_lock(&self->lock);
  gint fd = self->fd;
  g_mutex_unlock(&self->lock);
  if (fd < 0) {
    g_message("wristload: write 失败 self->fd=%d", fd);
    fl_method_call_respond_error(call, "rfcomm_write", "RFCOMM not connected",
                                 nullptr, nullptr);
    return;
  }
  const uint8_t* bytes = fl_value_get_uint8_list(args);
  size_t remaining = fl_value_get_length(args);
  while (remaining > 0) {
    ssize_t written = write(fd, bytes, remaining);
    if (written < 0) {
      if (errno == EINTR) continue;
      fl_method_call_respond_error(call, "rfcomm_write", g_strerror(errno),
                                   nullptr, nullptr);
      return;
    }
    bytes += written;
    remaining -= static_cast<size_t>(written);
  }
  fl_method_call_respond_success(call, nullptr, nullptr);
}

static void handle_disconnect(WristloadRfcommLinuxPlugin* self,
                              FlMethodCall* call) {
  close_current_socket(self);
  g_mutex_lock(&self->lock);
  g_free(self->device_path);
  self->device_path = NULL;
  g_mutex_unlock(&self->lock);
  unregister_profile(self, NULL);
  fl_method_call_respond_success(call, nullptr, nullptr);
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  WristloadRfcommLinuxPlugin* self = WRISTLOAD_RFCOMM_LINUX_PLUGIN(user_data);
  const gchar* method = fl_method_call_get_name(method_call);

  if (g_strcmp0(method, "ensurePermissions") == 0) {
    // Linux 无运行时蓝牙权限弹窗；BlueZ 由桌面会话策略控制。
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }
  if (g_strcmp0(method, "write") == 0) {
    handle_write(self, method_call);
    return;
  }
  if (g_strcmp0(method, "disconnect") == 0) {
    handle_disconnect(self, method_call);
    return;
  }
  if (g_strcmp0(method, "pair") == 0) {
    spawn_worker(self, method_call, TRUE);
    return;
  }
  if (g_strcmp0(method, "connect") == 0) {
    spawn_worker(self, method_call, FALSE);
    return;
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

// --- Event channel ---------------------------------------------------------

// Dart 订阅/取消时通知。事件实际发送由 FlEventChannel 内部管理
// （fl_event_channel_send 会直接编码并投递），这里无需保存 sink。
static FlMethodErrorResponse* event_listen_cb(FlEventChannel* channel,
                                              FlValue* args,
                                              gpointer user_data) {
  return nullptr;
}

static FlMethodErrorResponse* event_cancel_cb(FlEventChannel* channel,
                                              FlValue* args,
                                              gpointer user_data) {
  return nullptr;
}

// --- Registration ----------------------------------------------------------

void wristload_rfcomm_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  WristloadRfcommLinuxPlugin* plugin = WRISTLOAD_RFCOMM_LINUX_PLUGIN(
      g_object_new(wristload_rfcomm_linux_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* method_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "wristload/rfcomm",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      method_channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  plugin->events = fl_event_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "wristload/rfcomm/events",
      FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(plugin->events, event_listen_cb,
                                       event_cancel_cb, g_object_ref(plugin),
                                       g_object_unref);
}
