# wristload_rfcomm_linux

Wristload 的 Linux 经典蓝牙（BR/EDR）RFCOMM/SPP 传输桥。

通过 BlueZ 系统总线（org.bluez）实现：

- 设备解析（按 MAC 地址查找 Device1 对象路径）；
- 经典蓝牙配对（NoInputNoOutput 代理自动确认，绑定为 Just Works 流程）；
- SPP 服务连接（ProfileManager1 注册客户端 Profile + Device1.ConnectProfile，
  由 BlueZ 完成 SDP 查询并把已连接 socket 交给 NewConnection）；
- 数据读写与断开。

通道契约与 Android 原生桥一致：

- `MethodChannel('wristload/rfcomm')`：`ensurePermissions` / `pair` /
  `connect` / `write` / `disconnect`；
- `EventChannel('wristload/rfcomm/events')`：二进制数据包与
  `rfcomm_closed` / `rfcomm_read` 错误。

## 运行依赖

- BlueZ（bluetoothd）与系统总线 D-Bus；
- 桌面会话可访问 org.bluez（普通登录用户默认可配对/连接）。

## 构建依赖

- GLib/GIO（pkg-config `glib-2.0`、`gio-2.0`）。

## 已知限制

- 使用 NoInputNoOutput 配对代理，自动确认配对请求；需要用户在手表上
  确认/输入 PIN 的流程由 BlueZ 与系统桌面代理处理，未单独实现；
- 使用 BLE 扫描得到的设备地址建立 RFCOMM；若设备广告地址与经典蓝牙
  地址不一致，需先在系统设置中完成经典蓝牙配对。
