import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'ble_transport.dart';
import 'desktop_v2_connection.dart';

/// Windows V2 defers the beta0.1.3 pairing sequence to RFCOMM connection setup.
///
/// Pairing is intentionally not started in this preparation adapter. The native
/// Windows RFCOMM path first resolves/pairs the advertised BLE identity, then
/// waits for the classic identity and Serial Port Profile to be published.
class WindowsV2Connection implements DesktopV2Connection {
  const WindowsV2Connection();

  @override
  String get platformName => 'Windows';

  @override
  Future<String?> prepare({
    required BleTransport transport,
    required Peripheral peripheral,
    required String advertisedName,
    required bool directIdentity,
    required DesktopV2ConnectionLog log,
  }) async {
    log('Windows：准备阶段不单独绑定；RFCOMM 建链将按 beta0.1.3 顺序触发系统蓝牙配对。');
    return null;
  }
}
