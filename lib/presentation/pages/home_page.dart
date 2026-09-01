import 'dart:async';
import 'dart:io';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/device_controller.dart';
import '../../application/diagnostic_log_service.dart';
import '../../domain/auth_key_binding.dart';
import '../../domain/known_devices_store.dart';
import '../../domain/firmware_package_inspector.dart';
import '../../domain/install_file_classifier.dart';
import '../../domain/install_models.dart';
import '../../domain/install_task.dart';
import '../../domain/install_preference_store.dart';
import '../../domain/resource_install_target_policy.dart';
import '../../domain/queue_file_importer.dart';
import '../../platform/scoped_file_picker.dart';
import '../../platform/security_scoped_file_access.dart';
import '../device_info_page.dart';
import '../firmware_inspection_dialog.dart';
import '../home_widgets.dart';
import '../install_split_button.dart';
import '../install_task_card.dart';
import '../install_warning_dialog.dart';
import '../page_module.dart';

const wristloadPage = WristloadPageModule(
  id: 'home',
  route: '/',
  label: '首页',
  icon: Icons.home_outlined,
  selectedIcon: Icons.home,
  order: 0,
  build: _buildHomePage,
);

Widget _buildHomePage(WristloadPageContext context) => HomePage(
  controller: context.controller,
  preferredInstallTarget: context.preferredInstallTarget,
  onPreferredInstallTargetChanged: context.onPreferredInstallTargetChanged,
  onManageDevices: context.onEditAuthKey,
  diagnosticLogWindowOpen: context.diagnosticLogWindowOpen,
  onDiagnosticLogWindowChanged: context.onDiagnosticLogWindowChanged,
);
Future<void> openVerifiedDeviceInfo(
  BuildContext context,
  DeviceController controller,
) {
  if (!context.mounted || !DeviceInfoPage.hasVerifiedSession(controller)) {
    return Future<void>.value();
  }
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/device-info'),
      builder: (_) => DeviceInfoPage(controller: controller),
    ),
  );
}

class HomePage extends StatelessWidget {
  const HomePage({
    required this.controller,
    required this.preferredInstallTarget,
    required this.onPreferredInstallTargetChanged,
    this.onManageDevices,
    this.diagnosticLogWindowOpen = false,
    this.onDiagnosticLogWindowChanged,
    super.key,
  });

  final DeviceController controller;
  final InstallPreference preferredInstallTarget;
  final ValueChanged<InstallPreference> onPreferredInstallTargetChanged;
  final VoidCallback? onManageDevices;
  final bool diagnosticLogWindowOpen;
  final ValueChanged<bool>? onDiagnosticLogWindowChanged;

  Future<void> _pickFirmware(BuildContext context) async {
    final selected = await ScopedFilePicker.pickFiles(
      allowedExtensions: const ['zip', 'bin'],
    );
    final file = selected?.single;
    if (file == null || !context.mounted) return;
    await _inspectFirmware(context, file);
  }

  Future<void> _inspectFirmware(
    BuildContext context,
    ScopedFileRef file,
  ) async {
    final path = file.path;

    try {
      final inspection = await SecurityScopedFileAccess.instance.withAccess(
        file,
        (resolved) => const FirmwarePackageInspector().inspect(resolved.path),
      );
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => FirmwareInspectionDialog(inspection: inspection),
      );
    } on FormatException catch (error) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => FirmwareInspectionErrorDialog(
          fileName: path.split(RegExp(r'[/\\]')).last,
          message: error.message.toString(),
        ),
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => FirmwareInspectionErrorDialog(
          fileName: path.split(RegExp(r'[/\\]')).last,
          message: '读取固件包时发生错误：$error',
        ),
      );
    }
  }

  Future<void> _pickAndTry(
    BuildContext context,
    InstallKind kind, {
    List<String>? targetDeviceIds,
  }) async {
    final extensions = kind == InstallKind.watchface
        ? const ['bin', 'face']
        : Platform.isMacOS
        ? const ['rpk', 'bin']
        : const ['rpk'];
    final selected = await ScopedFilePicker.pickFiles(
      allowedExtensions: extensions,
    );
    final source = selected?.single;
    if (source == null) return;
    if (!context.mounted) return;
    // The content inspection below is macOS-specific because it must retain
    // the security-scoped bookmark returned by the native file picker. Other
    // platforms keep their established extension-based import path.
    if (!Platform.isMacOS) {
      await _prepareAndTry(
        context,
        source,
        kind,
        targetDeviceIds: targetDeviceIds,
      );
      return;
    }
    await _tryImportSource(
      context,
      source,
      expectedKind: kind,
      targetDeviceIds: targetDeviceIds,
    );
  }

  Future<void> _handleDrop(
    BuildContext context,
    DropDoneDetails details,
  ) async {
    for (final error in details.errors) {
      controller.reportError('无法拖入文件：${error.message}');
    }
    for (final file in details.files) {
      if (!context.mounted) return;
      await _tryImportSource(
        context,
        ScopedFileRef(path: file.path, bookmark: file.extraAppleBookmark),
      );
    }
  }

  Future<void> _tryImportSource(
    BuildContext context,
    ScopedFileRef source, {
    InstallKind? expectedKind,
    List<String>? targetDeviceIds,
  }) async {
    final fileName = source.path.split(RegExp(r'[/\\]')).last;
    if (!_isMacOSInstallCandidate(source.path)) {
      controller.reportError('不支持的安装文件：$fileName');
      return;
    }
    try {
      final classifiedSource = await const InstallFileClassifier()
          .classifySource(source);
      final classification = classifiedSource.type;
      final resolvedSource = classifiedSource.source;
      if (!context.mounted) return;
      switch (classification) {
        case InstallableFileType.firmware:
          if (expectedKind != null) {
            controller.reportError('所选文件是固件包，请使用固件检查入口。');
            return;
          }
          await _inspectFirmware(context, resolvedSource);
          return;
        case InstallableFileType.quickApp:
          if (expectedKind == InstallKind.watchface) {
            controller.reportError('所选文件是快应用，请从快应用入口安装。');
            return;
          }
          await _prepareAndTry(
            context,
            resolvedSource,
            InstallKind.quickApp,
            targetDeviceIds: targetDeviceIds,
          );
          return;
        case InstallableFileType.watchface:
          if (expectedKind == InstallKind.quickApp) {
            final suffix = fileName.toLowerCase().endsWith('.bin')
                ? '；合法快应用 .bin 必须同时包含 manifest.json 与 app.js 或 app.jsc'
                : '';
            controller.reportError('所选文件不是合法的快应用$suffix。');
            return;
          }
          await _prepareAndTry(
            context,
            resolvedSource,
            InstallKind.watchface,
            targetDeviceIds: targetDeviceIds,
          );
          return;
        case InstallableFileType.unsupported:
          controller.reportError('不支持的安装文件：$fileName');
          return;
      }
    } on Object catch (error) {
      controller.reportError('无法识别安装文件 $fileName：$error');
    }
  }

  bool _isMacOSInstallCandidate(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    // `.zip` is retained for drag-dropped firmware. The classifier accepts
    // it only when it contains ota.sh, so ordinary ZIP files never enter the
    // installation queue.
    return extension == 'zip' || InstallFileClassifier.supportsPath(path);
  }

  Future<void> _prepareAndTry(
    BuildContext context,
    ScopedFileRef source,
    InstallKind kind, {
    List<String>? targetDeviceIds,
  }) async {
    try {
      final importedRequest = await QueueFileImporter().prepareSingle(
        source,
        expectedKind: kind,
      );
      var metadata = importedRequest.metadata;
      var unsupportedLuaConfirmed = false;
      var watchfaceResolutionConfirmed = false;
      if (!context.mounted) return;
      final targets = targetDeviceIds == null
          ? await _resolveInstallTargets(context)
          : _resolveExplicitInstallTargets(targetDeviceIds);
      if (!context.mounted) return;
      if (targets == null || targets.isEmpty) return;
      if (kind == InstallKind.watchface) {
        final compatibilityIssues = _watchfaceCompatibilityIssues(
          metadata,
          targets,
        );
        if (compatibilityIssues.isNotEmpty) {
          watchfaceResolutionConfirmed = await _confirmWatchfaceResolution(
            context,
            metadata,
            compatibilityIssues,
          );
          if (!watchfaceResolutionConfirmed) return;
          if (!context.mounted) return;
        }
        final luaTargets = _unsupportedLuaTargets(metadata, targets);
        if (luaTargets.isNotEmpty) {
          unsupportedLuaConfirmed = await _confirmUnsupportedLuaWatchface(
            context,
            metadata,
            luaTargets,
          );
          if (!unsupportedLuaConfirmed) return;
          if (!context.mounted) return;
        }
        if (!context.mounted) return;
        final edited = await _editFaceId(context, metadata);
        if (edited == null || !context.mounted) return;
        metadata = edited;
      } else if (metadata.versionCode == null) {
        if (!context.mounted) return;
        final edited = await _editRpkVersion(context, metadata);
        if (edited == null || !context.mounted) return;
        metadata = edited;
      }
      if (kind == InstallKind.watchface &&
          !RegExp(r'^\d+$').hasMatch(metadata.faceId ?? '')) {
        throw const FormatException('faceId 必须为数值型 ID');
      }
      if (kind == InstallKind.quickApp &&
          (metadata.versionCode == null ||
              metadata.versionCode! <= 0 ||
              metadata.versionCode! > maxRpkVersionCode)) {
        throw const FormatException('RPK 清单未提供版本号，请填写有效 32 位正整数版本号');
      }
      controller.enqueue(
        importedRequest.copyWith(
          metadata: metadata,
          unsupportedLuaConfirmed: unsupportedLuaConfirmed,
          watchfaceResolutionConfirmed: watchfaceResolutionConfirmed,
          targetDeviceIds: targets.map((target) => target.id).toList(),
        ),
      );
      await controller.runQueue();
    } on Object catch (error) {
      controller.reportError('无法创建安装计划：$error');
    }
  }

  Future<List<ResourceInstallDevice>?> _resolveInstallTargets(
    BuildContext context,
  ) async {
    final devices = controller.resourceInstallDevices;
    if (devices.isEmpty) {
      controller.reportError('没有已连接且已验证的设备。');
      return null;
    }
    final policy = controller.resourceInstallTargetPolicy;
    if (policy.mode == ResourceInstallTargetMode.allConnected) return devices;
    if (policy.mode == ResourceInstallTargetMode.automaticDevice) {
      final matched = devices.where(
        (item) => item.id == policy.automaticDeviceId,
      );
      if (matched.isNotEmpty) return matched.toList();
      controller.reportError('自动安装目标已不在当前连接列表中，请重新选择安装设备。');
      return null;
    }
    return _showInstallTargetPicker(context, devices);
  }

  List<ResourceInstallDevice>? _resolveExplicitInstallTargets(
    List<String> targetDeviceIds,
  ) {
    final byId = <String, ResourceInstallDevice>{
      for (final device in controller.resourceInstallDevices)
        device.id.trim().toLowerCase(): device,
    };
    final targets = <ResourceInstallDevice>[];
    final seen = <String>{};
    for (final rawId in targetDeviceIds) {
      final normalized = rawId.trim().toLowerCase();
      if (normalized.isEmpty || !seen.add(normalized)) continue;
      final device = byId[normalized];
      if (device == null) {
        controller.reportError('目标设备已断开或尚未完成验证，未发送资源。');
        return null;
      }
      targets.add(device);
    }
    if (targets.isEmpty) {
      controller.reportError('没有可用的安装目标设备。');
      return null;
    }
    return targets;
  }

  List<_WatchfaceTargetIssue> _watchfaceCompatibilityIssues(
    InstallMetadata metadata,
    List<ResourceInstallDevice> targets,
  ) => [
    for (final target in targets)
      if (controller.watchfaceCompatibilityErrorForDevice(metadata, target.id)
          case final error?)
        _WatchfaceTargetIssue(device: target, error: error),
  ];

  List<ResourceInstallDevice> _unsupportedLuaTargets(
    InstallMetadata metadata,
    List<ResourceInstallDevice> targets,
  ) => [
    for (final target in targets)
      if (controller.requiresUnsupportedLuaConfirmationForDevice(
        metadata,
        target.id,
      ))
        target,
  ];

  Future<List<ResourceInstallDevice>?> _showInstallTargetPicker(
    BuildContext context,
    List<ResourceInstallDevice> devices,
  ) => showModalBottomSheet<List<ResourceInstallDevice>>(
    context: context,
    showDragHandle: true,
    builder: (_) => _InstallTargetPicker(devices: devices),
  );

  Future<bool> _confirmWatchfaceResolution(
    BuildContext context,
    InstallMetadata metadata,
    List<_WatchfaceTargetIssue> issues,
  ) async {
    var confirmed = false;
    final resolutions = metadata.watchfaceResolutions.isEmpty
        ? '未识别'
        : metadata.watchfaceResolutions.join('、');
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InstallWarningDialog(
        title: '表盘分辨率不匹配',
        message: '安装后可能无法正常显示或使用',
        rows: [
          ('表盘分辨率', resolutions, false),
          for (final issue in issues)
            (
              '设备分辨率',
              '${issue.device.name}：'
                  '${controller.sessionForDeviceId(issue.device.id)?.connectedProfile?.watchfaceResolution ?? '未知'}',
              true,
            ),
          ('文件名', metadata.fileName, false),
        ],
        onConfirm: () => confirmed = true,
      ),
    );
    return confirmed;
  }

  Future<bool> _confirmUnsupportedLuaWatchface(
    BuildContext context,
    InstallMetadata metadata,
    List<ResourceInstallDevice> targets,
  ) async {
    var confirmed = false;
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InstallWarningDialog(
        title: 'Lua 不被支持',
        message: '安装后可能无法正常显示或使用',
        rows: [
          ('文件名', metadata.fileName, false),
          ('检测结果', '检测到lua文件', true),
          ('目标设备', targets.map((target) => target.name).join('、'), false),
        ],
        onConfirm: () => confirmed = true,
      ),
    );
    return confirmed;
  }

  Future<InstallMetadata?> _editFaceId(
    BuildContext context,
    InstallMetadata metadata,
  ) async {
    // TextFormField owns its internal controller for the whole dialog route.
    // Keeping a controller in this caller and disposing it after showDialog
    // returns races the route's reverse animation on macOS.
    var faceId = metadata.faceId ?? '';
    final formKey = GlobalKey<FormState>();
    return showDialog<InstallMetadata>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('表盘 faceId'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: faceId,
            onChanged: (value) => faceId = value,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '从表盘资源解析，可按需编辑',
              border: OutlineInputBorder(),
            ),
            validator: (value) => RegExp(r'^\d+$').hasMatch(value ?? '')
                ? null
                : 'faceId 必须是非空数值',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                metadata.copyWith(faceId: faceId.trim()),
              );
            },
            child: const Text('继续'),
          ),
        ],
      ),
    );
  }

  Future<InstallMetadata?> _editRpkVersion(
    BuildContext context,
    InstallMetadata metadata,
  ) async {
    var versionText = '';
    final formKey = GlobalKey<FormState>();
    return showDialog<InstallMetadata>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('RPK 版本号'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: versionText,
            onChanged: (value) => versionText = value,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: '包名：${metadata.packageName}',
              helperText: '包名必须来自 RPK 清单，不能手动修改。',
              border: const OutlineInputBorder(),
            ),
            validator: (value) {
              final version = int.tryParse(value?.trim() ?? '');
              if (version == null ||
                  version <= 0 ||
                  version > maxRpkVersionCode) {
                return '请输入 1–$maxRpkVersionCode';
              }
              return null;
            },
            onFieldSubmitted: (value) {
              versionText = value;
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                metadata.copyWith(versionCode: int.parse(versionText.trim())),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                metadata.copyWith(versionCode: int.parse(versionText.trim())),
              );
            },
            child: const Text('继续'),
          ),
        ],
      ),
    );
  }

  /// authkey 是正式会话身份校验的必填输入。
  Future<void> _connectWithAuthKey(
    BuildContext context,
    DiscoveredEventArgs result,
  ) async {
    final deviceId = result.peripheral.uuid.toString();
    // 只读取本设备经认证后保存的 authkey；绝不能把另一台设备的凭据
    // 当作通用回退值。没有本设备记录时才请求用户输入。
    if (await controller.useSavedAuthKeyForDevice(deviceId)) {
      if (!context.mounted) return;
      await controller.connect(result);
      return;
    }
    if (!context.mounted) return;
    var authKey = '';
    final formKey = GlobalKey<FormState>();
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('输入 authkey'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: authKey,
            onChanged: (value) => authKey = value,
            autofocus: true,
            maxLength: 32,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              hintText: '32 位十六进制（绑定 token，16 字节）',
              counterText: '',
              border: OutlineInputBorder(),
            ),
            validator: (value) {
              final v = value?.trim() ?? '';
              if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(v)) {
                return '请输入 32 位十六进制字符';
              }
              return null;
            },
            onFieldSubmitted: (value) {
              authKey = value;
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, authKey.trim());
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, authKey.trim());
              }
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
    if (input != null &&
        await controller.setAuthKey(input, deviceId: deviceId)) {
      // The controller persists the device-specific binding only after f=27
      // confirms the authkey. A cancelled macOS pairing or failed RFCOMM
      // handshake must not create an apparent "saved device".
      await controller.connect(result);
    }
  }

  /// An extra device must never overwrite the primary controller's in-memory
  /// authkey. The child session created by [connectAdditional] owns this value
  /// and persists it only after that device finishes f=27 authentication.
  Future<void> _connectAdditionalWithAuthKey(
    BuildContext context,
    DiscoveredEventArgs result,
  ) async {
    final deviceId = result.peripheral.uuid.toString();
    final saved = await controller.readAuthKeyFor(deviceId);
    if (!context.mounted) return;

    final authKey =
        saved ??
        await _requestAdditionalDeviceAuthKey(
          context,
          title: '输入附加设备 authkey',
          deviceName: result.advertisement.name,
        );
    if (authKey == null || !context.mounted) return;
    await controller.connectAdditional(result, authKeyOverride: authKey);
  }

  Future<bool> _connectAdditionalSavedDeviceWithAuthKey(
    BuildContext context,
    AuthKeyBinding binding,
  ) async {
    final saved = await controller.readAuthKeyFor(binding.id);
    if (!context.mounted) return false;
    if (saved != null) {
      return controller.connectAdditionalSavedDevice(binding);
    }
    if (Platform.isWindows) {
      controller.reportError('Windows 多设备连接仅支持已有 authkey 的已保存设备。');
      return false;
    }
    final authKey = await _requestAdditionalDeviceAuthKey(
      context,
      title: '输入附加设备 authkey',
      deviceName: binding.name,
    );
    if (authKey == null || !context.mounted) return false;
    return controller.connectAdditionalSavedDevice(
      binding,
      authKeyOverride: authKey,
    );
  }

  Future<void> _showWindowsMultiDeviceDialog(BuildContext context) async {
    final candidates = <AuthKeyBinding>[];
    for (final binding in controller.authKeyBindings) {
      if (controller.isDeviceAlreadyInSession(binding.id)) continue;
      if (await controller.readAuthKeyFor(binding.id) != null) {
        candidates.add(binding);
      }
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('多设备连接'),
        content: SizedBox(
          width: 480,
          child: candidates.isEmpty
              ? const Text('没有可连接的第二台设备。请先确保设备已在 Windows 中配对，并已保存 authkey。')
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, index) {
                    final binding = candidates[index];
                    return ListTile(
                      leading: const Icon(Icons.watch_outlined),
                      title: Text(
                        binding.name.trim().isEmpty ? '已保存设备' : binding.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        binding.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.of(dialogContext).pop();
                        unawaited(
                          _connectAdditionalSavedDeviceWithAuthKey(
                            context,
                            binding,
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<String?> _requestAdditionalDeviceAuthKey(
    BuildContext context, {
    required String title,
    String? deviceName,
  }) async {
    var authKey = '';
    final formKey = GlobalKey<FormState>();
    final label = deviceName?.trim() ?? '';
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: authKey,
            onChanged: (value) => authKey = value,
            autofocus: true,
            maxLength: 32,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: label.isEmpty ? '32 位十六进制' : label,
              hintText: '绑定 token，16 字节',
              counterText: '',
              border: const OutlineInputBorder(),
            ),
            validator: (value) {
              final normalized = value?.trim() ?? '';
              return RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(normalized)
                  ? null
                  : '请输入 32 位十六进制字符';
            },
            onFieldSubmitted: (value) {
              authKey = value;
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, authKey.trim());
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, authKey.trim());
              }
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A selected peripheral is only a transport candidate until the
    // controller confirms an authenticated session. In particular, macOS
    // pairing cancellation can briefly leave a candidate behind. Do not let
    // that candidate unlock device actions in the UI.
    final connected = controller.isConnected;
    final canOpenDeviceInfo = DeviceInfoPage.hasVerifiedSession(controller);
    final device = connected ? controller.connectedDevice : null;
    final connecting = !connected && controller.isConnecting;
    final disconnecting =
        !connected && !connecting && controller.isConnectionBusy;
    final candidateName =
        (controller.connectedDeviceName ??
                controller.connectedProfile?.displayName ??
                '')
            .trim();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final battery = controller.batteryPercent;
    final hasBattery = battery != null && battery >= 0 && battery <= 100;
    final storageUsed = controller.storageUsedBytes;
    final storageTotal = controller.storageTotalBytes;
    final hasStorage =
        storageUsed != null &&
        storageTotal != null &&
        storageTotal > 0 &&
        storageUsed <= storageTotal;
    final additionalSessions = controller.additionalDeviceSessions;
    final additionalScanResults = controller.scanResults
        .where(controller.isAdditionalMacOSDeviceCandidate)
        .toList(growable: false);
    final primaryDeviceId = device?.uuid.toString();
    final multiDeviceMode =
        connected && primaryDeviceId != null && additionalSessions.isNotEmpty;
    final content = SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (multiDeviceMode)
                _MultiDeviceSessionPanel(
                  primarySession: DeviceSessionView(
                    id: primaryDeviceId,
                    name: candidateName.isEmpty ? '已连接设备' : candidateName,
                    controller: controller,
                    isPrimary: true,
                  ),
                  additionalSessions: additionalSessions,
                  targetPolicy: controller.resourceInstallTargetPolicy,
                  onSetTarget: (deviceId) =>
                      controller.setResourceInstallTargetPolicy(
                        ResourceInstallTargetPolicy(
                          mode: ResourceInstallTargetMode.automaticDevice,
                          automaticDeviceId: deviceId,
                        ),
                      ),
                  onDisconnectPrimary: controller.disconnect,
                  onDisconnectAdditional: (session) =>
                      controller.disconnectAdditionalDevice(session.id),
                  onManageDevices: onManageDevices,
                )
              else
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                connected
                                    ? '已连接：${candidateName.isEmpty ? '未知设备' : candidateName}'
                                    : connecting
                                    ? '正在连接：${candidateName.isEmpty ? '设备' : candidateName}'
                                    : disconnecting
                                    ? '正在断开连接…'
                                    : '尚未连接设备',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleLarge,
                              ),
                            ),
                            if (canOpenDeviceInfo)
                              IconButton(
                                key: const ValueKey('device-info-button'),
                                tooltip: '查看设备信息',
                                style: IconButton.styleFrom(
                                  side: BorderSide(
                                    color: colors.outlineVariant,
                                  ),
                                ),
                                icon: const Icon(Icons.chevron_right),
                                onPressed: () => unawaited(
                                  openVerifiedDeviceInfo(context, controller),
                                ),
                              ),
                          ],
                        ),
                        if (connected) ...[
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: colors.tertiary,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text('已连接', style: theme.textTheme.bodyMedium),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  device?.uuid.toString() ?? '设备身份读取中',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.end,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colors.onSurfaceVariant,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (connected && (hasBattery || hasStorage)) ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              if (hasBattery)
                                Expanded(
                                  child: _DeviceStat(
                                    icon: Icons.battery_std,
                                    value: '$battery%',
                                    detail: '电量',
                                    progress: battery / 100,
                                    progressColor: battery < 20
                                        ? colors.error
                                        : null,
                                  ),
                                ),
                              if (hasBattery && hasStorage)
                                const SizedBox(width: 12),
                              if (hasStorage)
                                Expanded(
                                  child: _DeviceStat(
                                    icon: Icons.sd_storage,
                                    value:
                                        '${_formatBytes(storageUsed)} / ${_formatBytes(storageTotal)}',
                                    detail: '存储',
                                    progress: storageUsed / storageTotal,
                                  ),
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 12),
                        if (!connected) ...[
                          _KnownDevicesSection(
                            controller: controller,
                            onConnect: (record) => unawaited(
                              controller.connectKnownDevice(record),
                            ),
                          ),
                        ],
                        if (!connected && controller.bluetoothUnavailable) ...[
                          _BluetoothUnavailableBanner(
                            message: controller.bluetoothStateMessage,
                            onOpenBluetoothPrivacySettings:
                                Platform.isMacOS &&
                                    controller
                                        .macOSBluetoothPrivacySettingsRequired
                                ? () => unawaited(
                                    controller
                                        .openMacOSBluetoothPrivacySettings(),
                                  )
                                : null,
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (!connected)
                          if (connecting || disconnecting)
                            Row(
                              children: [
                                const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    connecting ? '正在连接…' : '正在断开…',
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ),
                              ],
                            )
                          else if (controller.isScanning)
                            Row(
                              children: [
                                const ScanningPulseIndicator(),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '正在扫描附近的设备…',
                                        style: theme.textTheme.bodyMedium,
                                      ),
                                      Text(
                                        '找到 ${controller.scanResults.where(isInstallableDiscovery).length} 个可连接设备',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: colors.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                OutlinedButton.icon(
                                  onPressed: controller.stopScan,
                                  icon: const Icon(Icons.stop_circle_outlined),
                                  label: const Text('停止扫描'),
                                ),
                              ],
                            )
                          else
                            FilledButton.icon(
                              onPressed:
                                  controller.canScan &&
                                      !controller.isConnectionBusy
                                  ? controller.beginScan
                                  : null,
                              icon: const Icon(Icons.bluetooth_searching),
                              label: const Text('开始扫描'),
                            )
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                key: const ValueKey('disconnect-button'),
                                onPressed: controller.isConnectionBusy
                                    ? null
                                    : controller.disconnect,
                                icon: const Icon(Icons.link_off),
                                label: const Text('断开连接'),
                              ),
                              FilledButton.tonalIcon(
                                key: const ValueKey('manage-devices-button'),
                                onPressed: onManageDevices,
                                icon: const Icon(Icons.devices_outlined),
                                label: const Text('设备管理'),
                              ),
                              if (Platform.isWindows &&
                                  controller.supportsAdditionalWindowsDevices)
                                FilledButton.tonalIcon(
                                  key: const ValueKey(
                                    'connect-additional-windows-device-button',
                                  ),
                                  onPressed:
                                      controller
                                              .canConnectAdditionalDesktopDevice &&
                                          !controller.isConnectionBusy
                                      ? () => unawaited(
                                          _showWindowsMultiDeviceDialog(
                                            context,
                                          ),
                                        )
                                      : null,
                                  icon: const Icon(Icons.add_link),
                                  label: const Text('多设备连接'),
                                ),
                              if (Platform.isMacOS &&
                                  controller.supportsAdditionalMacOSDevices)
                                controller.isScanning
                                    ? OutlinedButton.icon(
                                        key: const ValueKey(
                                          'stop-additional-device-scan-button',
                                        ),
                                        onPressed: controller.stopScan,
                                        icon: const Icon(
                                          Icons.stop_circle_outlined,
                                        ),
                                        label: const Text('停止添加设备扫描'),
                                      )
                                    : FilledButton.tonalIcon(
                                        key: const ValueKey(
                                          'connect-additional-device-button',
                                        ),
                                        onPressed:
                                            controller.canScan &&
                                                !controller.isConnectionBusy
                                            ? controller.beginScan
                                            : null,
                                        icon: const Icon(Icons.add_link),
                                        label: const Text('连接多设备'),
                                      ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              if (controller.error case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (Platform.isMacOS &&
                  controller.supportsAdditionalMacOSDevices &&
                  (connected || additionalSessions.isNotEmpty) &&
                  controller.isScanning &&
                  additionalScanResults.isNotEmpty) ...[
                const SizedBox(height: 12),
                _AdditionalDeviceScanResults(
                  results: additionalScanResults,
                  onConnect: (result) =>
                      _connectAdditionalWithAuthKey(context, result),
                ),
              ] else if (!connected && !controller.isConnectionBusy) ...[
                const SizedBox(height: 12),
                ScanResultsList(
                  results: controller.scanResults,
                  onConnect: (result) => _connectWithAuthKey(context, result),
                ),
              ],
              if (connected) ...[
                const SizedBox(height: 12),
                Text('安装', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                InstallSplitButton(
                  preferredTarget: preferredInstallTarget,
                  enabled:
                      controller.sessionReady &&
                      !controller.installInProgress &&
                      !controller.timeSyncInProgress &&
                      !controller.statusRefreshInProgress,
                  onInstall: (target) => _pickAndTry(
                    context,
                    target,
                    targetDeviceIds: multiDeviceMode
                        ? null
                        : primaryDeviceId == null
                        ? null
                        : <String>[primaryDeviceId],
                  ),
                  onInstallFirmware: () => _pickFirmware(context),
                ),
                if (controller.latestTask case final task?)
                  InstallTaskCard(
                    task: task,
                    onCancel: controller.cancelInstall,
                    onRetry: controller.retryInstall,
                    onClear: controller.clearLatestTask,
                  ),
              ],
              const SizedBox(height: 12),
              DiagnosticLogToggle(
                entryCount: appLogger.length,
                enabled: diagnosticLogWindowOpen,
                onChanged: onDiagnosticLogWindowChanged,
              ),
            ],
          ),
        ),
      ),
    );
    if (!Platform.isMacOS) return content;
    return DropTarget(
      onDragDone: (details) => unawaited(_handleDrop(context, details)),
      child: content,
    );
  }
}

class _WatchfaceTargetIssue {
  const _WatchfaceTargetIssue({required this.device, required this.error});

  final ResourceInstallDevice device;
  final String error;
}

class _AdditionalDeviceScanResults extends StatelessWidget {
  const _AdditionalDeviceScanResults({
    required this.results,
    required this.onConnect,
  });

  final List<DiscoveredEventArgs> results;
  final ValueChanged<DiscoveredEventArgs> onConnect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final result in results)
          ScanTile(
            key: ValueKey(
              'additional-scan-' + result.peripheral.uuid.toString(),
            ),
            result: result,
            installable: true,
            onConnect: () => onConnect(result),
          ),
      ],
    );
  }
}

class _MultiDeviceSessionPanel extends StatelessWidget {
  const _MultiDeviceSessionPanel({
    required this.primarySession,
    required this.additionalSessions,
    required this.targetPolicy,
    required this.onSetTarget,
    required this.onDisconnectPrimary,
    required this.onDisconnectAdditional,
    required this.onManageDevices,
  });

  final DeviceSessionView primarySession;
  final List<DeviceSessionView> additionalSessions;
  final ResourceInstallTargetPolicy targetPolicy;
  final ValueChanged<String> onSetTarget;
  final Future<void> Function() onDisconnectPrimary;
  final Future<void> Function(DeviceSessionView session) onDisconnectAdditional;
  final VoidCallback? onManageDevices;

  bool _isTarget(String deviceId) =>
      targetPolicy.mode == ResourceInstallTargetMode.automaticDevice &&
      targetPolicy.automaticDeviceId == deviceId;

  @override
  Widget build(BuildContext context) {
    final sessions = <DeviceSessionView>[primarySession, ...additionalSessions];
    return Card(
      key: const ValueKey('multi-device-session-panel'),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final horizontal =
              sessions.length == 2 && constraints.maxWidth >= 720;
          final cards = <Widget>[
            for (final session in sessions)
              _MultiDeviceCard(
                key: ValueKey('multi-device-card-${session.id}'),
                session: session,
                selectedTarget: _isTarget(session.id),
                onSetTarget: () => onSetTarget(session.id),
                onDisconnect: session.isPrimary
                    ? onDisconnectPrimary
                    : () => onDisconnectAdditional(session),
                onManageDevices: onManageDevices,
              ),
          ];
          if (!horizontal) {
            return Column(
              children: [
                for (var index = 0; index < cards.length; index++) ...[
                  cards[index],
                  if (index != cards.length - 1) const Divider(height: 1),
                ],
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < cards.length; index++)
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: index == 0
                          ? null
                          : Border(
                              left: BorderSide(
                                color: Theme.of(
                                  context,
                                ).colorScheme.outlineVariant,
                              ),
                            ),
                    ),
                    child: cards[index],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _MultiDeviceCard extends StatelessWidget {
  const _MultiDeviceCard({
    required this.session,
    required this.selectedTarget,
    required this.onSetTarget,
    required this.onDisconnect,
    required this.onManageDevices,
    super.key,
  });

  final DeviceSessionView session;
  final bool selectedTarget;
  final VoidCallback onSetTarget;
  final Future<void> Function() onDisconnect;
  final VoidCallback? onManageDevices;

  @override
  Widget build(BuildContext context) {
    final controller = session.controller;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final connected = controller.isConnected;
    final connecting = !connected && controller.isConnecting;
    final busy = controller.isConnectionBusy;
    final name = session.name.trim().isEmpty ? '已连接设备' : session.name.trim();
    final status = connected
        ? '已连接'
        : connecting
        ? '正在连接'
        : busy
        ? '正在断开'
        : '连接失败';
    final statusColor = connected
        ? colors.tertiary
        : connecting || busy
        ? colors.primary
        : colors.error;
    final battery = controller.batteryPercent;
    final hasBattery = battery != null && battery >= 0 && battery <= 100;
    final storageUsed = controller.storageUsedBytes;
    final storageTotal = controller.storageTotalBytes;
    final hasStorage =
        storageUsed != null &&
        storageTotal != null &&
        storageTotal > 0 &&
        storageUsed <= storageTotal;
    final canOpenDeviceInfo = DeviceInfoPage.hasVerifiedSession(controller);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: selectedTarget
                      ? colors.primaryContainer
                      : colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  connected ? Icons.watch : Icons.bluetooth,
                  color: selectedTarget
                      ? colors.onPrimaryContainer
                      : colors.onSurface,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      session.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              if (canOpenDeviceInfo)
                IconButton(
                  key: ValueKey('multi-device-info-${session.id}'),
                  tooltip: '查看设备信息',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () =>
                      unawaited(openVerifiedDeviceInfo(context, controller)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(status, style: theme.textTheme.bodySmall),
            ],
          ),
          if (connected && (hasBattery || hasStorage)) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (hasBattery)
                  Expanded(
                    child: _DeviceStat(
                      icon: Icons.battery_std,
                      value: '$battery%',
                      detail: '电量',
                      progress: battery / 100,
                      progressColor: battery < 20 ? colors.error : null,
                    ),
                  ),
                if (hasBattery && hasStorage) const SizedBox(width: 10),
                if (hasStorage)
                  Expanded(
                    child: _DeviceStat(
                      icon: Icons.sd_storage,
                      value:
                          '${_formatBytes(storageUsed)} / ${_formatBytes(storageTotal)}',
                      detail: '存储',
                      progress: storageUsed / storageTotal,
                    ),
                  ),
              ],
            ),
          ],
          if (controller.error case final error?) ...[
            const SizedBox(height: 10),
            Text(
              error,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
            ),
          ],
          const SizedBox(height: 16),
          _MultiDeviceActions(
            sessionId: session.id,
            selectedTarget: selectedTarget,
            onDisconnect: onDisconnect,
            onSetTarget: onSetTarget,
            onManageDevices: onManageDevices,
          ),
        ],
      ),
    );
  }
}

class _MultiDeviceActions extends StatelessWidget {
  const _MultiDeviceActions({
    required this.sessionId,
    required this.selectedTarget,
    required this.onDisconnect,
    required this.onSetTarget,
    required this.onManageDevices,
  });

  final String sessionId;
  final bool selectedTarget;
  final Future<void> Function() onDisconnect;
  final VoidCallback onSetTarget;
  final VoidCallback? onManageDevices;

  @override
  Widget build(BuildContext context) {
    final disconnectButton = OutlinedButton.icon(
      key: ValueKey('disconnect-device-$sessionId'),
      onPressed: () => unawaited(onDisconnect()),
      icon: const Icon(Icons.link_off, size: 18),
      label: const Text('断开连接'),
    );
    final manageButton = FilledButton.tonalIcon(
      key: ValueKey('manage-devices-$sessionId'),
      onPressed: onManageDevices,
      icon: const Icon(Icons.devices_outlined, size: 18),
      label: const Text('设备管理'),
    );
    final targetButton = selectedTarget
        ? FilledButton.tonalIcon(
            key: ValueKey('install-target-$sessionId'),
            onPressed: onSetTarget,
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: const Text('安装目标'),
          )
        : OutlinedButton.icon(
            key: ValueKey('set-install-target-$sessionId'),
            onPressed: onSetTarget,
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('设为安装目标'),
          );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 300) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              disconnectButton,
              const SizedBox(height: 8),
              manageButton,
              const SizedBox(height: 8),
              targetButton,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: disconnectButton),
                const SizedBox(width: 8),
                Expanded(child: manageButton),
              ],
            ),
            const SizedBox(height: 8),
            targetButton,
          ],
        );
      },
    );
  }
}

class _KnownDevicesSection extends StatelessWidget {
  const _KnownDevicesSection({
    required this.controller,
    required this.onConnect,
  });

  final DeviceController controller;
  final ValueChanged<KnownDeviceRecord> onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => FutureBuilder<List<KnownDeviceRecord>>(
        future: controller.loadKnownDevices(),
        builder: (context, snapshot) {
          final devices = snapshot.data ?? const <KnownDeviceRecord>[];
          if (devices.isEmpty) return const SizedBox.shrink();
          final bindings = controller.authKeyBindings;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('已保存设备', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              ...devices.map((record) {
                final bound = bindings.any(
                  (b) => b.id.toLowerCase() == record.id.toLowerCase(),
                );
                return Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.watch_outlined),
                    title: Text(
                      record.name.trim().isEmpty ? '已保存设备' : record.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        '上次连接 ${_formatRelativeTime(record.lastConnectedAt)}',
                        if (bound) 'authkey 已保存',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => onConnect(record),
                  ),
                );
              }),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

String _formatRelativeTime(DateTime time) {
  final difference = DateTime.now().difference(time);
  if (difference.inMinutes < 1) return '刚刚';
  if (difference.inHours < 1) return '${difference.inMinutes} 分钟前';
  if (difference.inDays < 1) return '${difference.inHours} 小时前';
  if (difference.inDays < 30) return '${difference.inDays} 天前';
  return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
}

class _BluetoothUnavailableBanner extends StatelessWidget {
  const _BluetoothUnavailableBanner({
    required this.message,
    this.onOpenBluetoothPrivacySettings,
  });

  final String message;
  final VoidCallback? onOpenBluetoothPrivacySettings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('bluetooth-unavailable-banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.error.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.bluetooth_disabled, color: colors.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ),
            ],
          ),
          if (onOpenBluetoothPrivacySettings != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('open-bluetooth-privacy-settings'),
                onPressed: onOpenBluetoothPrivacySettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('打开蓝牙隐私设置'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 设备卡片上的统计块（电量/存储）。
class _DeviceStat extends StatelessWidget {
  const _DeviceStat({
    required this.icon,
    required this.value,
    required this.detail,
    required this.progress,
    this.progressColor,
  });

  final IconData icon;
  final String value;
  final String detail;
  final double progress;
  final Color? progressColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.onSurface),
              const SizedBox(width: 6),
              Text(
                detail,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 4,
              color: progressColor ?? theme.colorScheme.primary,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(1)} KB';
}

class _InstallTargetPicker extends StatefulWidget {
  const _InstallTargetPicker({required this.devices});

  final List<ResourceInstallDevice> devices;

  @override
  State<_InstallTargetPicker> createState() => _InstallTargetPickerState();
}

class _InstallTargetPickerState extends State<_InstallTargetPicker> {
  bool _multiple = false;
  late final Set<String> _selected = {widget.devices.first.id};

  void _toggle(ResourceInstallDevice device, bool selected) {
    setState(() {
      if (_multiple) {
        selected ? _selected.add(device.id) : _selected.remove(device.id);
      } else {
        _selected
          ..clear()
          ..add(device.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedDevices = widget.devices
        .where((device) => _selected.contains(device.id))
        .toList(growable: false);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '选择安装设备',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _multiple = !_multiple;
                    if (!_multiple && _selected.length > 1) {
                      _selected
                        ..clear()
                        ..add(widget.devices.first.id);
                    }
                  }),
                  child: Text(_multiple ? '单选' : '多选'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (final device in widget.devices)
              Card(
                margin: const EdgeInsets.only(top: 8),
                child: ListTile(
                  leading: const Icon(Icons.watch_outlined),
                  title: Text(device.name.isEmpty ? '已连接设备' : device.name),
                  subtitle: Text(
                    device.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: _multiple
                      ? Checkbox(
                          value: _selected.contains(device.id),
                          onChanged: (value) => _toggle(device, value ?? false),
                        )
                      : Radio<String>(
                          value: device.id,
                          groupValue: _selected.firstOrNull,
                          onChanged: (_) => _toggle(device, true),
                        ),
                  onTap: () => _toggle(device, !_selected.contains(device.id)),
                ),
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: selectedDevices.isEmpty
                    ? null
                    : () => Navigator.pop(context, selectedDevices),
                child: Text('安装到 ${selectedDevices.length} 台设备'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
