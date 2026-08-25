import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wristload/application/device_controller.dart';
import 'package:wristload/domain/auth_key_binding.dart';
import 'package:wristload/domain/install_preference_store.dart';
import 'package:wristload/presentation/pages/home_page.dart' as app;

void main() {
  testWidgets('已连接卡片只在统计块显示电量并放大设备名称', (tester) async {
    final deviceUuid = UUID.fromAddress('A1:B2:C3:D4:E5:F6');
    final controller = _ConnectionStateController(connected: true)
      ..connectedDevice = _TestPeripheral(deviceUuid)
      ..connectedDeviceName = 'REDMI Watch 5'
      ..batteryPercent = 100;
    addTearDown(controller.dispose);

    final theme = ThemeData(
      textTheme: const TextTheme(
        titleMedium: TextStyle(fontSize: 16),
        titleLarge: TextStyle(fontSize: 24),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: app.HomePage(
            controller: controller,
            preferredInstallTarget: InstallPreference.watchface,
            onPreferredInstallTargetChanged: (_) {},
            onManageDevices: () {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));

    final title = tester.widget<Text>(find.text('已连接：REDMI Watch 5'));
    expect(title.style?.fontSize, 24);
    expect(find.text('已连接'), findsOneWidget);
    expect(find.text('电量 100%'), findsNothing);
    expect(find.text('电量'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.byIcon(Icons.battery_std), findsOneWidget);
    expect(find.text(deviceUuid.toString()), findsOneWidget);
    expect(find.text('设备管理'), findsOneWidget);
    expect(find.text('重新连接'), findsNothing);

    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.minHeight, 4);
    expect(progress.backgroundColor, theme.colorScheme.surfaceContainerHighest);
    final clip = tester.widget<ClipRRect>(
      find.ancestor(
        of: find.byType(LinearProgressIndicator),
        matching: find.byType(ClipRRect),
      ),
    );
    expect(clip.borderRadius, BorderRadius.circular(2));
  });

  testWidgets('未连接的候选设备不会显示已连接页面或设备操作', (tester) async {
    final controller = _ConnectionStateController(connected: false)
      ..connectedDevice = _TestPeripheral(UUID.fromAddress('A1:B2:C3:D4:E5:F6'))
      ..connectedDeviceName = 'Xiaomi Smart Band 10 9D63';
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    expect(find.text('尚未连接设备'), findsOneWidget);
    expect(find.text('已连接：Xiaomi Smart Band 10 9D63'), findsNothing);
    expect(find.byKey(const ValueKey('device-info-button')), findsNothing);
    expect(find.byKey(const ValueKey('disconnect-button')), findsNothing);
    expect(find.text('安装'), findsNothing);
  });

  testWidgets('已连接后不显示蓝牙不可用提醒', (tester) async {
    final controller =
        _ConnectionStateController(connected: true, unavailable: true)
          ..connectedDevice = _TestPeripheral(
            UUID.fromAddress('A1:B2:C3:D4:E5:F6'),
          )
          ..connectedDeviceName = 'Xiaomi Smart Band 10';
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    expect(
      find.byKey(const ValueKey('bluetooth-unavailable-banner')),
      findsNothing,
    );
  });

  testWidgets('未连接且蓝牙明确不可用时显示提醒', (tester) async {
    final controller = _ConnectionStateController(
      connected: false,
      unavailable: true,
    );
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    expect(
      find.byKey(const ValueKey('bluetooth-unavailable-banner')),
      findsOneWidget,
    );
  });

  testWidgets('连接中的候选设备只显示连接进度，不显示详情或安装', (tester) async {
    final controller = _ConnectionStateController(connected: false)
      ..connectedDevice = _TestPeripheral(UUID.fromAddress('A1:B2:C3:D4:E5:F6'))
      ..connectedDeviceName = 'Xiaomi Smart Band 10 9D63'
      ..sppConnecting = true;
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    expect(find.text('正在连接：Xiaomi Smart Band 10 9D63'), findsOneWidget);
    expect(find.text('正在建立设备连接，完成验证后即可使用设备功能。'), findsOneWidget);
    expect(find.byKey(const ValueKey('device-info-button')), findsNothing);
    expect(find.byKey(const ValueKey('disconnect-button')), findsNothing);
    expect(find.text('安装'), findsNothing);
  });

  testWidgets('主页不显示已保存设备区域', (tester) async {
    final binding = AuthKeyBinding(
      id: '896fcdf6-7b32-1f45-e5f5-fa09eec80de3',
      name: 'Xiaomi Smart Band 10',
      uuid: '896fcdf6-7b32-1f45-e5f5-fa09eec80de3',
      updatedAt: DateTime(2026, 8, 15),
    );
    final controller = _SavedDevicesController([binding]);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    expect(find.byKey(const ValueKey('saved-devices-section')), findsNothing);
    expect(find.text('已保存设备'), findsNothing);
    expect(find.text('Xiaomi Smart Band 10'), findsNothing);
    expect(find.text(binding.id), findsNothing);
  });

  testWidgets('第二设备连接失败时双卡仍正常渲染', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final primaryId = UUID.fromAddress('A1:B2:C3:D4:E5:F6');
    final secondaryId = UUID.fromAddress('06:05:04:03:02:01');
    final secondary = _ConnectionStateController(connected: false)
      ..error = 'RFCOMM 连接失败';
    final controller =
        _MultiDeviceController(
            DeviceSessionView(
              id: secondaryId.toString(),
              name: 'Xiaomi Smart Band 9 Pro CCF2',
              controller: secondary,
              isPrimary: false,
            ),
          )
          ..connectedDevice = _TestPeripheral(primaryId)
          ..connectedDeviceName = 'Xiaomi Smart Band 10 AA28'
          ..batteryPercent = 42;
    addTearDown(secondary.dispose);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('multi-device-session-panel')),
      findsOneWidget,
    );
    expect(find.text('Xiaomi Smart Band 10 AA28'), findsOneWidget);
    expect(find.text('Xiaomi Smart Band 9 Pro CCF2'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('连接失败'), findsOneWidget);
    expect(find.text('RFCOMM 连接失败'), findsOneWidget);
  });
}

Future<void> _pumpHome(WidgetTester tester, DeviceController controller) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: app.HomePage(
          controller: controller,
          preferredInstallTarget: InstallPreference.watchface,
          onPreferredInstallTargetChanged: (_) {},
          onManageDevices: () {},
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 150));
}

class _ConnectionStateController extends DeviceController {
  _ConnectionStateController({
    required this.connected,
    this.unavailable = false,
  });

  final bool connected;
  final bool unavailable;

  @override
  bool get isConnected => connected;

  @override
  bool get bluetoothUnavailable => unavailable;
}

class _SavedDevicesController extends _ConnectionStateController {
  _SavedDevicesController(this.savedBindings) : super(connected: false);

  final List<AuthKeyBinding> savedBindings;
  @override
  List<AuthKeyBinding> get authKeyBindings => savedBindings;

  @override
  set authKeyBindings(List<AuthKeyBinding> value) {}
}

class _MultiDeviceController extends _ConnectionStateController {
  _MultiDeviceController(this.secondarySession) : super(connected: true);

  final DeviceSessionView secondarySession;

  @override
  List<DeviceSessionView> get additionalDeviceSessions => [secondarySession];
}

class _TestPeripheral implements Peripheral {
  const _TestPeripheral(this.uuid);

  @override
  final UUID uuid;
}
