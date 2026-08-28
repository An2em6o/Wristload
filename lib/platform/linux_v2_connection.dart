import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'ble_transport.dart';
import 'desktop_v2_connection.dart';

/// Linux V2 preparation relies on BlueZ: the native RFCOMM bridge resolves the
/// advertised identity, ensures the classic-Bluetooth bond, and connects the
/// SPP service during RFCOMM setup.
class LinuxV2Connection implements DesktopV2Connection {
  const LinuxV2Connection();

  @override
  String get platformName => 'Linux';

  @override
  Future<String?> prepare({
    required BleTransport transport,
    required Peripheral peripheral,
    required String advertisedName,
    required bool directIdentity,
    required DesktopV2ConnectionLog log,
  }) async {
    transport.listenRfcommData();
    log('Linux：使用 BlueZ 建立经典蓝牙配对；SPP 连接在 RFCOMM 建链阶段完成。');
    return transport.pairDevice(peripheral.uuid, advertisedName: advertisedName);
  }
}
