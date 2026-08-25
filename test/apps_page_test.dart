import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wristload/application/device_controller.dart';
import 'package:wristload/domain/watch_app.dart';
import 'package:wristload/presentation/pages/apps_page.dart';

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('快应用页在会话就绪后只自动读取一次，并在断开后为下一会话重置', (tester) async {
    final controller = _AppsPageController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppsPage(controller: controller)),
      ),
    );
    await tester.pump();
    expect(controller.refreshCalls, 0);

    controller.setSessionReady(true);
    await tester.pump();
    await tester.pump();
    expect(controller.refreshCalls, 1);

    controller.notifyListeners();
    await tester.pump();
    expect(controller.refreshCalls, 1);

    controller.setSessionReady(false);
    await tester.pump();
    controller.setSessionReady(true);
    await tester.pump();
    await tester.pump();
    expect(controller.refreshCalls, 2);
  });

  testWidgets('macOS 快应用卡片会启动对应的设备应用', (tester) async {
    final controller = _AppsPageController()
      ..installedWatchApps = <WatchAppItem>[
        WatchAppItem(
          packageName: 'com.example.demo',
          fingerprint: Uint8List.fromList(const [0x01, 0xab]),
          versionCode: 1,
          canRemove: true,
          appName: 'Demo',
        ),
      ]
      ..setSessionReady(true);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppsPage(controller: controller)),
      ),
    );
    await tester.pump();

    expect(find.text('Demo'), findsOneWidget);
    expect(find.text('com.example.demo'), findsOneWidget);
    expect(find.text('版本'), findsNothing);
    expect(find.text('指纹'), findsNothing);
    expect(find.text('1'), findsNothing);
    expect(find.text('01:AB'), findsNothing);
    expect(find.text('启动'), findsOneWidget);
    await tester.tap(find.text('启动'));
    await tester.pump();

    expect(controller.launchCalls, 1);
    expect(controller.lastLaunched?.packageName, 'com.example.demo');
  });
}

class _AppsPageController extends DeviceController {
  int refreshCalls = 0;
  int launchCalls = 0;
  WatchAppItem? lastLaunched;

  void setSessionReady(bool value) {
    sessionReady = value;
    notifyListeners();
  }

  @override
  Future<List<WatchAppItem>> refreshInstalledWatchApps() async {
    refreshCalls++;
    return installedWatchApps;
  }

  @override
  Future<bool> launchWatchApp(WatchAppItem app) async {
    launchCalls++;
    lastLaunched = app;
    return true;
  }
}
