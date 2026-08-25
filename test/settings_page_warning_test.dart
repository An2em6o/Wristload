import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wristload/domain/device_profile.dart';
import 'package:wristload/domain/install_preference_store.dart';
import 'package:wristload/domain/resource_install_target_policy.dart';
import 'package:wristload/application/device_controller.dart';
import 'package:wristload/presentation/pages/settings_page.dart';

void main() {
  const allConnectedLabel = '所有已连接设备';
  const primaryWarning = '同一资源可能与部分设备不兼容。';

  testWidgets('所有设备安装需在五秒警告后确认才会保存', (tester) async {
    ResourceInstallTargetPolicy? changed;
    await tester.pumpWidget(
      _settingsPage(
        onResourceInstallTargetPolicyChanged: (value) => changed = value,
      ),
    );

    expect(find.text(allConnectedLabel), findsOneWidget);
    await tester.tap(find.text(allConnectedLabel));
    await tester.pump();

    expect(find.text(primaryWarning), findsOneWidget);
    expect(find.text('多设备安装存在兼容性风险。5 秒后可确认。'), findsOneWidget);
    final countdownWarning = tester.widget<Text>(
      find.byKey(const ValueKey('all-connected-install-warning')),
    );
    expect(
      countdownWarning.style?.color,
      Theme.of(tester.element(find.byType(AlertDialog))).colorScheme.error,
    );
    final initialConfirm = find.widgetWithText(FilledButton, '确认开启（5）');
    expect(tester.widget<FilledButton>(initialConfirm).onPressed, isNull);
    expect(changed, isNull);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(changed, isNull);

    await tester.tap(find.text(allConnectedLabel));
    await tester.pump();
    for (var secondsLeft = 4; secondsLeft > 0; secondsLeft--) {
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('确认开启（$secondsLeft）'), findsOneWidget);
      expect(find.text('多设备安装存在兼容性风险。$secondsLeft 秒后可确认。'), findsOneWidget);
    }

    await tester.pump(const Duration(seconds: 1));
    final enabledConfirm = find.widgetWithText(FilledButton, '确认开启');
    expect(tester.widget<FilledButton>(enabledConfirm).onPressed, isNotNull);
    expect(find.text('多设备安装存在兼容性风险。0 秒后可确认。'), findsOneWidget);

    await tester.tap(enabledConfirm);
    await tester.pumpAndSettle();
    expect(changed?.mode, ResourceInstallTargetMode.allConnected);
  });

  testWidgets('关闭所有设备安装警告不会更改当前策略', (tester) async {
    ResourceInstallTargetPolicy? changed;
    await tester.pumpWidget(
      _settingsPage(
        onResourceInstallTargetPolicyChanged: (value) => changed = value,
      ),
    );

    await tester.tap(find.text(allConnectedLabel));
    await tester.pump();
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();

    expect(find.text('确认开启多设备安装？'), findsNothing);
    expect(changed, isNull);
  });

  testWidgets('双设备安装目标只勾选指定设备', (tester) async {
    const firstId = 'device-aa28';
    const secondId = 'device-ccf2';
    ResourceInstallTargetPolicy? changed;
    await tester.pumpWidget(
      _settingsPage(
        resourceInstallTargetPolicy: const ResourceInstallTargetPolicy(
          mode: ResourceInstallTargetMode.automaticDevice,
          automaticDeviceId: firstId,
        ),
        resourceInstallDevices: const [
          ResourceInstallDevice(id: firstId, name: 'Xiaomi Smart Band 10 AA28'),
          ResourceInstallDevice(
            id: secondId,
            name: 'Xiaomi Smart Band 9 Pro CCF2',
          ),
        ],
        onResourceInstallTargetPolicyChanged: (value) => changed = value,
      ),
    );

    final deviceTiles = tester
        .widgetList<RadioListTile<String>>(find.byType(RadioListTile<String>))
        .where((tile) => tile.value.startsWith('device:'))
        .toList();
    expect(deviceTiles, hasLength(2));
    expect(
      deviceTiles.where((tile) => tile.value == tile.groupValue),
      hasLength(1),
    );
    expect(deviceTiles.first.value, 'device:$firstId');
    expect(deviceTiles.first.groupValue, 'device:$firstId');

    await tester.tap(find.text('Xiaomi Smart Band 9 Pro CCF2'));
    expect(changed?.mode, ResourceInstallTargetMode.automaticDevice);
    expect(changed?.automaticDeviceId, secondId);
  });

  testWidgets('macOS 显示强制安装表盘开关并转发变更', (tester) async {
    bool? changed;
    await tester.pumpWidget(
      _settingsPage(
        showForceWatchfaceInstall: true,
        onForceWatchfaceInstallChanged: (value) => changed = value,
      ),
    );

    await tester.scrollUntilVisible(
      find.text('强制安装表盘'),
      250,
      scrollable: find.byType(Scrollable),
    );
    final tileFinder = find.ancestor(
      of: find.text('强制安装表盘'),
      matching: find.byType(SwitchListTile),
    );
    final tile = tester.widget<SwitchListTile>(tileFinder);
    expect(tile.value, isFalse);
    expect(find.text('删除同 ID 表盘后安装'), findsOneWidget);

    await tester.tap(tileFinder);
    expect(changed, isTrue);
  });

  testWidgets('macOS 悬浮安装窗入口可用并在确认后转发变更', (tester) async {
    bool? changed;
    await tester.pumpWidget(
      _settingsPage(
        onFloatingInstallWindowEnabledChanged: (value) => changed = value,
      ),
    );

    await tester.scrollUntilVisible(
      find.text('启用悬浮安装窗'),
      250,
      scrollable: find.byType(Scrollable),
    );
    final tileFinder = find.ancestor(
      of: find.text('启用悬浮安装窗'),
      matching: find.byType(SwitchListTile),
    );
    final tile = tester.widget<SwitchListTile>(tileFinder);
    expect(tile.onChanged, isNotNull);
    expect(find.text('仅支持 Windows 和 macOS'), findsNothing);

    await tester.tap(tileFinder);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(changed, isNull);

    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(changed, isTrue);
  });
}

Widget _settingsPage({
  ValueChanged<ResourceInstallTargetPolicy>?
  onResourceInstallTargetPolicyChanged,
  bool showForceWatchfaceInstall = false,
  ValueChanged<bool>? onForceWatchfaceInstallChanged,
  ResourceInstallTargetPolicy resourceInstallTargetPolicy =
      const ResourceInstallTargetPolicy(),
  List<ResourceInstallDevice> resourceInstallDevices = const [],
  ValueChanged<bool>? onFloatingInstallWindowEnabledChanged,
}) => MaterialApp(
  home: Scaffold(
    body: TransferSettingsPage(
      connectionMode: ConnectionMode.modern,
      preferredInstallTarget: InstallPreference.watchface,
      connectionModeEnabled: true,
      segmentIntervalMs: 5,
      massWindowSize: 3,
      resourceInstallTargetPolicy: resourceInstallTargetPolicy,
      resourceInstallDevices: resourceInstallDevices,
      onConnectionModeChanged: (_) {},
      onSegmentIntervalChanged: (_) {},
      onMassWindowSizeChanged: (_) {},
      onPreferredInstallTargetChanged: (_) {},
      onResourceInstallTargetPolicyChanged:
          onResourceInstallTargetPolicyChanged,
      showForceWatchfaceInstall: showForceWatchfaceInstall,
      onForceWatchfaceInstallChanged: onForceWatchfaceInstallChanged,
      onFloatingInstallWindowEnabledChanged:
          onFloatingInstallWindowEnabledChanged,
    ),
  ),
);
