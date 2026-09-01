import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:window_manager/window_manager.dart';

import 'application/device_controller.dart';
import 'application/diagnostic_log_service.dart';
import 'application/performance_diagnostic_service.dart';
import 'application/diagnostic_log_window_coordinator.dart';
import 'application/floating_window_coordinator.dart';
import 'application/theme_controller.dart';
import 'domain/auth_key_binding.dart';
import 'domain/connection_issue.dart';
import 'domain/diagnostic_log_preferences.dart';
import 'domain/firmware_package_inspector.dart';
import 'domain/install_models.dart';
import 'domain/install_preference_store.dart';
import 'domain/install_task.dart';
import 'domain/oobe_store.dart';
import 'domain/queue_file_importer.dart';
import 'presentation/device_info_page.dart';
import 'presentation/app_theme.dart';
import 'presentation/generated_page_registry.dart';
import 'presentation/diagnostic_log_window_app.dart';
import 'presentation/connection_warning_dialog.dart';
import 'presentation/firmware_inspection_dialog.dart';
import 'presentation/floating_install_window_app.dart';
import 'presentation/home_widgets.dart';
import 'presentation/install_split_button.dart';
import 'presentation/install_task_card.dart';
import 'presentation/install_warning_dialog.dart';
import 'presentation/install_request_preflight.dart';
import 'presentation/oobe_logo_animation.dart';
import 'presentation/oobe_page.dart';
import 'presentation/page_module.dart';
import 'platform/scoped_file_picker.dart';
import 'platform/security_scoped_file_access.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  _installGlobalErrorHandlers();
  await appLogger.initializePersistence();
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
    final currentWindow = await WindowController.fromCurrentEngine();
    if (currentWindow.arguments == diagnosticLogWindowArgument) {
      appLogger.info(
        'diagnostic log window engine started',
        category: DiagnosticLogCategory.runtime,
        fields: <String, Object?>{'platform': Platform.operatingSystem},
      );
      runApp(const DiagnosticLogWindowApp());
      return;
    }
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      await windowManager.setPreventClose(true);
    }
    if ((Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
        currentWindow.arguments == floatingInstallWindowArgument) {
      appLogger.info(
        'floating install window engine started',
        category: DiagnosticLogCategory.runtime,
        fields: <String, Object?>{'platform': Platform.operatingSystem},
      );
      runApp(const FloatingInstallWindowApp());
      return;
    }
  }
  appLogger.info(
    'application started',
    category: DiagnosticLogCategory.runtime,
    fields: <String, Object?>{
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'dartVersion': Platform.version.split(' ').first,
      'flutterMode': kReleaseMode
          ? 'release'
          : (kProfileMode ? 'profile' : 'debug'),
      'locale': Platform.localeName,
      'argumentsCount': args.length,
    },
  );
  final startupValues = await Future.wait([
    OobeStore().readCompleted(),
    InstallPreferenceStore().readPreference(),
    ThemeController.create(),
    DiagnosticLogPreferences().readAutoOpen(),
  ]);
  final initialThemeController = startupValues[2] as ThemeController;
  final initialThemeSeedColor = initialThemeController.seedColor;
  final initialTianyiBlueUnlocked = initialThemeController.tianyiBlueUnlocked;
  initialThemeController.dispose();
  appLogger.debug(
    'startup configuration loaded',
    category: DiagnosticLogCategory.runtime,
    fields: <String, Object?>{
      'oobeCompleted': startupValues[0] as bool,
      'installPreference': (startupValues[1] as InstallPreference).name,
    },
  );
  runApp(
    WristloadApp(
      desktopIntegrationEnabled: Platform.isWindows || Platform.isMacOS || Platform.isLinux,
      initialOobeCompleted: startupValues[0] as bool,
      initialPreference: startupValues[1] as InstallPreference,
      initialThemeSeedColor: initialThemeSeedColor,
      initialTianyiBlueUnlocked: initialTianyiBlueUnlocked,
      initialAutoOpenDiagnosticLog: startupValues[3] as bool,
    ),
  );
}

void _installGlobalErrorHandlers() {
  FlutterError.onError = (details) {
    appLogger.error(
      'Flutter unhandled exception',
      category: DiagnosticLogCategory.runtime,
      fields: <String, Object?>{
        'errorType': details.exception.runtimeType.toString(),
        'exception': details.exceptionAsString(),
        'stackTrace': details.stack?.toString(),
      },
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    appLogger.fatal(
      'Platform unhandled exception',
      category: DiagnosticLogCategory.runtime,
      fields: <String, Object?>{
        'errorType': error.runtimeType.toString(),
        'exception': error.toString(),
        'stackTrace': stackTrace.toString(),
      },
    );
    return true;
  };
}

class WristloadApp extends StatefulWidget {
  const WristloadApp({
    this.desktopIntegrationEnabled = false,
    this.initialOobeCompleted = false,
    this.initialPreference = InstallPreference.watchface,
    this.initialThemeSeedColor = ThemeController.defaultSeedColor,
    this.initialTianyiBlueUnlocked = false,
    this.initialAutoOpenDiagnosticLog = false,
    super.key,
  });

  final bool desktopIntegrationEnabled;
  final bool initialOobeCompleted;
  final InstallPreference initialPreference;
  final Color initialThemeSeedColor;
  final bool initialTianyiBlueUnlocked;
  final bool initialAutoOpenDiagnosticLog;

  @override
  State<WristloadApp> createState() => _WristloadAppState();
}

class _WristloadAppState extends State<WristloadApp>
    with WidgetsBindingObserver, WindowListener {
  final controller = DeviceController(logger: appLogger);
  final _performanceDiagnostics = PerformanceDiagnosticService();
  final _appShellKey = GlobalKey<_AppShellState>();
  final _installRequestPreflight = const InstallRequestPreflight();
  final _installPreferenceStore = InstallPreferenceStore();
  final _oobeStore = OobeStore();
  final _diagnosticLogPreferences = DiagnosticLogPreferences();
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final FloatingWindowCoordinator _floatingWindowCoordinator;
  late final DiagnosticLogWindowCoordinator _diagnosticLogWindowCoordinator;
  bool _floatingInstallWindowEnabled = false;
  bool _diagnosticLogWindowOpen = false;
  late bool _autoOpenDiagnosticLog;
  late bool _oobeCompleted;
  late InstallPreference _preferredInstallTarget;
  late final ThemeController _themeController;
  Future<void> _preferenceWrites = Future.value();
  bool _floatingInitialized = false;
  bool _macOSPermissionRefreshInFlight = false;
  bool _exitCleanupStarted = false;

  @override
  void initState() {
    super.initState();
    _performanceDiagnostics.stateSnapshotProvider =
        _buildPerformanceStateSnapshot;
    unawaited(_performanceDiagnostics.start());
    if (Platform.isMacOS) {
      WidgetsBinding.instance.addObserver(this);
    }
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      // 主窗口关闭监听兜底：FloatingWindowCoordinator 初始化成功后也会注册
      // 同一监听并自行处理关闭；未初始化时（如未完成 OOBE）这里保证点关闭
      // 按钮能真正退出进程，而不是被 setPreventClose 静默拦截。
      windowManager.addListener(this);
    }
    _oobeCompleted = widget.initialOobeCompleted;
    _preferredInstallTarget = widget.initialPreference;
    _autoOpenDiagnosticLog = widget.initialAutoOpenDiagnosticLog;
    _themeController = ThemeController(
      widget.initialThemeSeedColor,
      tianyiBlueUnlocked: widget.initialTianyiBlueUnlocked,
    );
    _diagnosticLogWindowCoordinator = DiagnosticLogWindowCoordinator(
      logger: appLogger,
      onClear: controller.clearLogs,
      onClosed: _handleDiagnosticWindowClosed,
      themeSeedProvider: () => _themeController.seedColor,
    );
    controller.queueInstallPreparer = _prepareQueuedRequest;
    _floatingWindowCoordinator = FloatingWindowCoordinator(
      controller: controller,
      onOpenMainWindow: () => _appShellKey.currentState?.showHome(),
      onExitRequested: _exitApplication,
      themeSeedProvider: () => _themeController.seedColor,
    );
    if (widget.desktopIntegrationEnabled && _oobeCompleted) {
      unawaited(_initializeFloatingWindow());
    }
    if ((Platform.isWindows || Platform.isMacOS || Platform.isLinux) && _autoOpenDiagnosticLog) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_setDiagnosticLogWindowOpen(true));
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!Platform.isMacOS || state != AppLifecycleState.resumed) return;
    unawaited(_refreshMacOSBluetoothPermissionAfterResume());
  }

  Future<void> _refreshMacOSBluetoothPermissionAfterResume() async {
    if (_macOSPermissionRefreshInFlight || !mounted) return;
    _macOSPermissionRefreshInFlight = true;
    try {
      await controller.refreshMacOSBluetoothAuthorization();
    } finally {
      _macOSPermissionRefreshInFlight = false;
    }
  }

  void _setOobePreference(InstallPreference preference) {
    if (_preferredInstallTarget == preference) return;
    setState(() => _preferredInstallTarget = preference);
    _preferenceWrites = _preferenceWrites.then(
      (_) => _installPreferenceStore.writePreference(preference),
    );
  }

  Future<void> _completeOobe() async {
    await _preferenceWrites;
    await _installPreferenceStore.writePreference(_preferredInstallTarget);
    await _oobeStore.markCompleted();
    if (!mounted) return;
    setState(() => _oobeCompleted = true);
    _navigatorKey.currentState?.pushNamedAndRemoveUntil('/', (_) => false);
    if (widget.desktopIntegrationEnabled) {
      unawaited(_initializeFloatingWindow());
    }
  }

  Future<void> _replayOobe() async {
    await _oobeStore.markNotCompleted();
    if (!mounted) return;
    setState(() => _oobeCompleted = false);
    _navigatorKey.currentState?.pushNamedAndRemoveUntil('/oobe', (_) => false);
  }

  Widget _buildOobePage() => OobePage(
    installPreference: _preferredInstallTarget,
    onInstallPreferenceChanged: _setOobePreference,
    onCompleted: _completeOobe,
  );

  Future<void> _unlockTianyiBlue() async {
    await _themeController.unlockTianyiBlue();
    await Future.wait([
      _floatingWindowCoordinator.updateTheme(),
      _diagnosticLogWindowCoordinator.updateTheme(),
    ]);
  }

  Widget _buildAppShell() => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => AppShell(
      key: _appShellKey,
      controller: controller,
      preferredInstallTarget: _preferredInstallTarget,
      onPreferredInstallTargetChanged: _setOobePreference,
      onReplayOobe: _replayOobe,
      floatingInstallWindowEnabled: _floatingInstallWindowEnabled,
      themeSeedColor: _themeController.seedColor,
      tianyiBlueUnlocked: _themeController.tianyiBlueUnlocked,
      onThemeSeedChanged: (color) {
        unawaited(_themeController.setSeed(color));
        unawaited(_floatingWindowCoordinator.updateTheme());
        unawaited(_diagnosticLogWindowCoordinator.updateTheme());
      },
      onUnlockTianyiBlue: _unlockTianyiBlue,
      onFloatingInstallWindowEnabledChanged: widget.desktopIntegrationEnabled
          ? (enabled) {
              unawaited(_setFloatingInstallWindowEnabled(enabled));
            }
          : null,
      diagnosticLogWindowOpen: _diagnosticLogWindowOpen,
      autoOpenDiagnosticLog: _autoOpenDiagnosticLog,
      onDiagnosticLogWindowChanged: (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
          ? _setDiagnosticLogWindowOpen
          : null,
      onAutoOpenDiagnosticLogChanged: (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
          ? _setAutoOpenDiagnosticLog
          : null,
      performanceDiagnostics: _performanceDiagnostics,
    ),
  );

  Future<void> _setDiagnosticLogWindowOpen(bool open) async {
    try {
      if (open) {
        await _diagnosticLogWindowCoordinator.show();
      } else {
        await _diagnosticLogWindowCoordinator.hide();
      }
      if (!mounted) return;
      if (mounted) setState(() => _diagnosticLogWindowOpen = open);
      appLogger.info(
        open ? 'diagnostic log window opened' : 'diagnostic log window hidden',
        category: DiagnosticLogCategory.ui,
      );
    } on Object catch (error, stackTrace) {
      appLogger.error(
        'diagnostic log window operation failed',
        category: DiagnosticLogCategory.ui,
        fields: <String, Object?>{
          'operation': open ? 'show' : 'hide',
          'errorType': error.runtimeType.toString(),
          'exception': error.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
      if (mounted) setState(() => _diagnosticLogWindowOpen = false);
    }
  }

  Future<void> _setAutoOpenDiagnosticLog(bool enabled) async {
    try {
      await _diagnosticLogPreferences.writeAutoOpen(enabled);
      if (!mounted) return;
      setState(() => _autoOpenDiagnosticLog = enabled);
      appLogger.info(
        enabled
            ? 'automatic diagnostic log enabled'
            : 'automatic diagnostic log disabled',
        category: DiagnosticLogCategory.ui,
      );
    } on Object catch (error, stackTrace) {
      appLogger.error(
        'startup log preference save failed',
        category: DiagnosticLogCategory.ui,
        fields: <String, Object?>{
          'enabled': enabled,
          'errorType': error.runtimeType.toString(),
          'exception': error.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
    }
  }

  void _handleDiagnosticWindowClosed() {
    if (!mounted || !_diagnosticLogWindowOpen) return;
    setState(() => _diagnosticLogWindowOpen = false);
    appLogger.info(
      'diagnostic log window closed',
      category: DiagnosticLogCategory.ui,
    );
  }

  Future<InstallRequest?> _prepareQueuedRequest(InstallRequest request) async {
    var context = _appShellKey.currentContext;
    if (context == null || !context.mounted) return null;
    if (widget.desktopIntegrationEnabled &&
        _installRequestPreflight.requiresInteraction(controller, request)) {
      await _floatingWindowCoordinator.showMainWindow();
      context = _appShellKey.currentContext;
      if (context == null || !context.mounted) return null;
    }
    return _installRequestPreflight.prepare(context, controller, request);
  }

  Future<void> _initializeFloatingWindow() async {
    if (_floatingInitialized) return;
    _floatingInitialized = true;
    try {
      await _floatingWindowCoordinator.initialize();
      if (!mounted) return;
      setState(() {
        _floatingInstallWindowEnabled = _floatingWindowCoordinator.enabled;
      });
    } on Object catch (error, stackTrace) {
      _floatingInitialized = false;
      appLogger.error(
        'Floating window initialization failed: $error',
        category: DiagnosticLogCategory.ui,
        fields: <String, Object?>{
          'errorType': error.runtimeType.toString(),
          'exception': error.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
    }
  }

  Future<void> _setFloatingInstallWindowEnabled(bool enabled) async {
    try {
      await _floatingWindowCoordinator.setEnabled(enabled);
      if (!mounted) return;
      setState(() {
        _floatingInstallWindowEnabled = _floatingWindowCoordinator.enabled;
      });
    } on Object catch (error, stackTrace) {
      appLogger.error(
        'Floating window setting failed: $error',
        category: DiagnosticLogCategory.ui,
        fields: <String, Object?>{
          'errorType': error.runtimeType.toString(),
          'exception': error.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
    }
  }

  String _buildPerformanceStateSnapshot() => <String>[
    'bluetooth state: ${controller.bluetoothState.name}',
    'scanning: ${controller.isScanning}',
    'connecting: ${controller.isConnecting}',
    'connected: ${controller.isConnected}',
    'session ready: ${controller.sessionReady}',
    'installing: ${controller.installInProgress}',
    'queue running: ${controller.queueRunning}',
    'pending installs: ${controller.pendingCount}',
    'connection mode: ${controller.connectionMode.name}',
    'device profile: ${controller.connectedProfile?.displayName ?? 'none'}',
    'firmware version: ${controller.connectedFirmwareVersion ?? 'unknown'}',
    'floating install window: $_floatingInstallWindowEnabled',
    'diagnostic log window: $_diagnosticLogWindowOpen',
  ].join('\n');

  Future<void> _exitApplication() async {
    if (_exitCleanupStarted) return;
    _exitCleanupStarted = true;
    controller.queueInstallPreparer = null;
    appLogger.info(
      'Desktop application shutdown started',
      category: DiagnosticLogCategory.runtime,
    );

    // Hide the visible window before bounded native cleanup so the desktop
    // shell does not leave an unresponsive window on screen during shutdown.
    try {
      await windowManager.hide().timeout(const Duration(milliseconds: 300));
    } on Object {
      // Destruction below remains the authoritative exit operation.
    }

    try {
      await Future.wait<void>([
        _diagnosticLogWindowCoordinator.shutdown().timeout(
          const Duration(milliseconds: 700),
        ),
        controller.disconnect().timeout(const Duration(seconds: 1)),
        _performanceDiagnostics.shutdown(),
      ]).timeout(const Duration(milliseconds: 1100));
    } on Object catch (error) {
      appLogger.warning(
        'Background cleanup did not complete before exit',
        category: DiagnosticLogCategory.runtime,
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
    }

    try {
      await windowManager
          .setPreventClose(false)
          .timeout(const Duration(milliseconds: 200));
    } on Object {
      // Continue to the final process-exit fallback.
    }
    try {
      await windowManager.destroy().timeout(const Duration(milliseconds: 500));
    } on Object {
      // A blocked desktop plugin must not leave the process behind.
    } finally {
      if (Platform.isWindows || Platform.isLinux) exit(0);
    }
  }

  @override
  void onWindowClose() {
    // 协调器注册监听后自行处理关闭（托盘隐藏或优雅退出）；未初始化时这里
    // 兜底直接退出，避免关闭按钮被 setPreventClose 拦截后进程无法结束。
    if (_floatingWindowCoordinator.isInitialized) return;
    unawaited(_exitApplication());
  }

  @override
  void dispose() {
    if (Platform.isMacOS) {
      WidgetsBinding.instance.removeObserver(this);
    }
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.removeListener(this);
    }
    controller.queueInstallPreparer = null;
    unawaited(_floatingWindowCoordinator.dispose());
    unawaited(_diagnosticLogWindowCoordinator.dispose());
    controller.dispose();
    _performanceDiagnostics.dispose();
    _themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _themeController,
    builder: (context, _) => MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildWristloadTheme(
        seedColor: _themeController.seedColor,
        brightness: Brightness.light,
      ),
      darkTheme: buildWristloadTheme(
        seedColor: _themeController.seedColor,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      initialRoute: _oobeCompleted ? '/' : '/oobe',
      onGenerateInitialRoutes: (initialRouteName) => [
        MaterialPageRoute<void>(
          settings: RouteSettings(name: initialRouteName),
          builder: (_) =>
              initialRouteName == '/oobe' ? _buildOobePage() : _buildAppShell(),
        ),
      ],
      routes: {
        '/': (context) => _buildAppShell(),
        '/oobe': (context) => _buildOobePage(),
        for (final module in generatedPageModules.where(
          (module) =>
              module.route != '/' && module.isAvailableOnCurrentPlatform,
        ))
          module.route: (context) => _buildRegisteredPage(module),
      },
    ),
  );

  Widget _buildRegisteredPage(WristloadPageModule module) => module.build(
    WristloadPageContext(
      controller: controller,
      preferredInstallTarget: _preferredInstallTarget,
      onPreferredInstallTargetChanged: _setOobePreference,
      floatingInstallWindowEnabled: _floatingInstallWindowEnabled,
      onFloatingInstallWindowEnabledChanged: widget.desktopIntegrationEnabled
          ? (enabled) => unawaited(_setFloatingInstallWindowEnabled(enabled))
          : null,
      autoOpenDiagnosticLog: _autoOpenDiagnosticLog,
      onAutoOpenDiagnosticLogChanged: (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
          ? _setAutoOpenDiagnosticLog
          : null,
      diagnosticLogWindowOpen: _diagnosticLogWindowOpen,
      onDiagnosticLogWindowChanged: (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
          ? _setDiagnosticLogWindowOpen
          : null,
      themeSeedColor: _themeController.seedColor,
      tianyiBlueUnlocked: _themeController.tianyiBlueUnlocked,
      onThemeSeedChanged: (color) {
        unawaited(_themeController.setSeed(color));
        unawaited(_floatingWindowCoordinator.updateTheme());
        unawaited(_diagnosticLogWindowCoordinator.updateTheme());
      },
      onUnlockTianyiBlue: _unlockTianyiBlue,
      onReplayOobe: _replayOobe,
      onEditAuthKey: () => _appShellKey.currentState?._editAuthKey(),
      performanceDiagnostics: _performanceDiagnostics,
    ),
  );
}

class AppShell extends StatefulWidget {
  const AppShell({
    required this.controller,
    required this.preferredInstallTarget,
    required this.onPreferredInstallTargetChanged,
    required this.onReplayOobe,
    required this.floatingInstallWindowEnabled,
    required this.onFloatingInstallWindowEnabledChanged,
    required this.themeSeedColor,
    required this.onThemeSeedChanged,
    required this.tianyiBlueUnlocked,
    required this.onUnlockTianyiBlue,
    required this.performanceDiagnostics,
    this.diagnosticLogWindowOpen = false,
    this.autoOpenDiagnosticLog = false,
    this.onDiagnosticLogWindowChanged,
    this.onAutoOpenDiagnosticLogChanged,
    super.key,
  });

  final DeviceController controller;
  final InstallPreference preferredInstallTarget;
  final ValueChanged<InstallPreference> onPreferredInstallTargetChanged;
  final Future<void> Function() onReplayOobe;
  final bool floatingInstallWindowEnabled;
  final Color themeSeedColor;
  final ValueChanged<Color> onThemeSeedChanged;
  final bool tianyiBlueUnlocked;
  final AsyncCallback onUnlockTianyiBlue;
  final PerformanceDiagnosticService performanceDiagnostics;
  final ValueChanged<bool>? onFloatingInstallWindowEnabledChanged;
  final bool diagnosticLogWindowOpen;
  final bool autoOpenDiagnosticLog;
  final ValueChanged<bool>? onDiagnosticLogWindowChanged;
  final ValueChanged<bool>? onAutoOpenDiagnosticLogChanged;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  int? _scheduledConnectionIssueId;
  int? _visibleConnectionIssueId;
  int? _scheduledConnectionFailureReportId;
  int? _visibleConnectionFailureReportId;
  bool _initialScanScheduled = false;
  bool _initialScanInFlight = false;
  bool _initialScanCompleted = false;
  bool _pairingScanScheduled = false;
  late bool _wasConnectionActive;
  String? _lastPerformanceState;

  bool get _connectionActive =>
      widget.controller.isConnected || widget.controller.isConnectionBusy;

  List<WristloadPageModule> get _pageModules => List<WristloadPageModule>.of(
    generatedPageModules.where((module) => module.isAvailableOnCurrentPlatform),
  )..sort((a, b) => a.order.compareTo(b.order));

  WristloadPageContext _pageContext() => WristloadPageContext(
    controller: widget.controller,
    preferredInstallTarget: widget.preferredInstallTarget,
    onPreferredInstallTargetChanged: widget.onPreferredInstallTargetChanged,
    floatingInstallWindowEnabled: widget.floatingInstallWindowEnabled,
    onFloatingInstallWindowEnabledChanged:
        widget.onFloatingInstallWindowEnabledChanged,
    autoOpenDiagnosticLog: widget.autoOpenDiagnosticLog,
    onAutoOpenDiagnosticLogChanged: widget.onAutoOpenDiagnosticLogChanged,
    diagnosticLogWindowOpen: widget.diagnosticLogWindowOpen,
    onDiagnosticLogWindowChanged: widget.onDiagnosticLogWindowChanged,
    themeSeedColor: widget.themeSeedColor,
    onThemeSeedChanged: widget.onThemeSeedChanged,
    tianyiBlueUnlocked: widget.tianyiBlueUnlocked,
    onUnlockTianyiBlue: widget.onUnlockTianyiBlue,
    onReplayOobe: widget.onReplayOobe,
    onEditAuthKey: _editAuthKey,
    performanceDiagnostics: widget.performanceDiagnostics,
  );

  NavigationRailDestination _navigationDestination(WristloadPageModule module) {
    Widget icon(IconData iconData) {
      if (module.id != 'queue') return Icon(iconData);
      return Badge.count(
        count: widget.controller.pendingCount,
        isLabelVisible: widget.controller.pendingCount > 0,
        child: Icon(iconData),
      );
    }

    return NavigationRailDestination(
      icon: icon(module.icon),
      selectedIcon: icon(module.selectedIcon),
      label: Text(module.label),
    );
  }

  @override
  void initState() {
    super.initState();
    _wasConnectionActive = _connectionActive;
    _recordSelectedPage();
    widget.controller.addListener(_handleControllerChanged);
    _handleControllerChanged();
    _scheduleInitialScan();
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleControllerChanged);
    _wasConnectionActive = _connectionActive;
    widget.controller.addListener(_handleControllerChanged);
    _scheduledConnectionIssueId = null;
    _visibleConnectionIssueId = null;
    _scheduledConnectionFailureReportId = null;
    _visibleConnectionFailureReportId = null;
    _handleControllerChanged();
  }

  void _handleControllerChanged() {
    _handleConnectionFailureReport();
    _handleConnectionIssue();
    final performanceState = <String>[
      'scanning=${widget.controller.isScanning}',
      'connecting=${widget.controller.isConnecting}',
      'connected=${widget.controller.isConnected}',
      'sessionReady=${widget.controller.sessionReady}',
      'installing=${widget.controller.installInProgress}',
      'queueRunning=${widget.controller.queueRunning}',
    ].join(' ');
    if (_lastPerformanceState != performanceState) {
      _lastPerformanceState = performanceState;
      widget.performanceDiagnostics.recordBehavior(
        'application state changed: $performanceState',
      );
    }
    final active = _connectionActive;
    _scheduleInitialScan();
    // V2 devices can briefly replace their first RFCOMM socket immediately
    // after f=27.  A connection is only over once it has left the verified,
    // connecting, and native-teardown states, not merely when sessionReady
    // changes for that transport transition.
    if (_wasConnectionActive && !active) {
      _wasConnectionActive = false;
      showHome();
      // Failed classic pairing and RFCOMM setup must remain visible for
      // diagnosis. Only an explicit user disconnect requests scan recovery.
      if (widget.controller.shouldResumeScanningAfterConnectionEnd) {
        _schedulePairingScan();
      }
      return;
    }
    _wasConnectionActive = active;
  }

  void _scheduleInitialScan() {
    if (!mounted ||
        _initialScanCompleted ||
        _initialScanScheduled ||
        _initialScanInFlight) {
      return;
    }
    if (widget.controller.isScanning) {
      _initialScanCompleted = true;
      return;
    }
    if (widget.controller.isConnected || widget.controller.isConnectionBusy) {
      return;
    }
    // The Windows Bluetooth state can still be initializing during the first
    // frame. Keep the one-shot startup request pending until the controller
    // reports that scanning is available instead of losing it permanently.
    if (!widget.controller.canScan) return;

    _initialScanScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _initialScanScheduled = false;
      if (!mounted ||
          _initialScanCompleted ||
          _initialScanInFlight ||
          widget.controller.isConnected ||
          widget.controller.isConnectionBusy) {
        return;
      }
      if (widget.controller.isScanning) {
        _initialScanCompleted = true;
        return;
      }
      if (!widget.controller.canScan) return;

      _initialScanInFlight = true;
      try {
        // Startup discovery is passive: it populates nearby devices but never
        // selects a saved binding or starts a connection.
        await widget.controller.beginStartupScan();
        _initialScanCompleted = widget.controller.isScanning;
      } finally {
        _initialScanInFlight = false;
      }
    });
  }

  void _recordSelectedPage() {
    final modules = _pageModules;
    if (modules.isEmpty || _selectedIndex >= modules.length) return;
    final module = modules[_selectedIndex];
    widget.performanceDiagnostics.recordPage(
      id: module.id,
      route: module.route,
      label: module.label,
    );
  }

  void _selectPage(int index) {
    if (index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
    _recordSelectedPage();
  }

  void _handleConnectionFailureReport() {
    final report = widget.controller.pendingConnectionFailureReport;
    if (!mounted ||
        report == null ||
        report.id == _scheduledConnectionFailureReportId ||
        report.id == _visibleConnectionFailureReportId) {
      return;
    }
    _scheduledConnectionFailureReportId = report.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_showConnectionFailureReport(report.id));
    });
  }

  Future<void> _showConnectionFailureReport(int reportId) async {
    if (_visibleConnectionFailureReportId != null ||
        _visibleConnectionIssueId != null) {
      return;
    }
    final report = widget.controller.pendingConnectionFailureReport;
    if (report == null || report.id != reportId) {
      if (_scheduledConnectionFailureReportId == reportId) {
        _scheduledConnectionFailureReportId = null;
      }
      _handleConnectionFailureReport();
      return;
    }
    _scheduledConnectionFailureReportId = null;
    _visibleConnectionFailureReportId = reportId;
    try {
      await showConnectionFailureReport(context: context, report: report);
    } finally {
      widget.controller.dismissConnectionFailureReport(reportId);
      _visibleConnectionFailureReportId = null;
      _handleConnectionFailureReport();
    }
  }

  void _schedulePairingScan() {
    if (_pairingScanScheduled) return;
    _pairingScanScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _pairingScanScheduled = false;
      if (!mounted ||
          widget.controller.isConnected ||
          widget.controller.isConnectionBusy ||
          widget.controller.isScanning ||
          !widget.controller.shouldResumeScanningAfterConnectionEnd ||
          !widget.controller.canScan) {
        return;
      }
      await widget.controller.beginScan();
    });
  }

  void _handleConnectionIssue() {
    // The detailed connection report is the primary failure UI. Defer the
    // generic authkey/timeout warning until the report has been dismissed.
    if (widget.controller.pendingConnectionFailureReport != null) return;
    final issue = widget.controller.pendingConnectionIssue;
    if (!mounted ||
        issue == null ||
        issue.id == _scheduledConnectionIssueId ||
        issue.id == _visibleConnectionIssueId) {
      return;
    }
    _scheduledConnectionIssueId = issue.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_showPendingConnectionIssue(issue.id));
    });
  }

  Future<void> _showPendingConnectionIssue(int issueId) async {
    if (_visibleConnectionIssueId != null) return;
    final issue = widget.controller.pendingConnectionIssue;
    if (issue == null || issue.id != issueId) {
      if (_scheduledConnectionIssueId == issueId) {
        _scheduledConnectionIssueId = null;
      }
      _handleConnectionIssue();
      return;
    }
    _scheduledConnectionIssueId = null;
    _visibleConnectionIssueId = issueId;
    try {
      if (issue.kind == ConnectionIssueKind.authKeyMismatch) {
        await _editAuthKey(
          showHistory: false,
          deviceId: issue.targetId,
          deviceName: issue.targetName,
        );
        return;
      }
      await showConnectionIssueWarning(
        context: context,
        issue: issue,
        onReconnect: widget.controller.reconnect,
        onChangeAuthKey: () => _editAuthKey(showHistory: false),
      );
    } finally {
      widget.controller.dismissConnectionIssue(issueId);
      _visibleConnectionIssueId = null;
      _handleConnectionIssue();
    }
  }

  void showHome() {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.popUntil((route) => route.isFirst);
    }
    final homeIndex = _pageModules.indexWhere((module) => module.id == 'home');
    if (homeIndex >= 0 && _selectedIndex != homeIndex) {
      setState(() => _selectedIndex = homeIndex);
      _recordSelectedPage();
    }
  }

  Future<void> _editAuthKey({
    bool showHistory = true,
    String? deviceId,
    String? deviceName,
  }) async {
    if (!mounted) return;
    final controller = widget.controller;
    AuthKeyBinding? selectedBinding;
    if (showHistory) {
      try {
        await controller.authKeyBindingsReady.timeout(
          const Duration(milliseconds: 800),
        );
      } on Object {
        // Opening the editor must not be blocked by a slow preference read.
      }
      if (!mounted) return;
    }
    if (showHistory && controller.authKeyBindings.isNotEmpty) {
      selectedBinding = await showDialog<AuthKeyBinding>(
        context: context,
        builder: (_) => _AuthKeyBindingPicker(
          bindings: controller.authKeyBindings,
          onDelete: (binding) => controller.deleteSavedDeviceById(binding.id),
          onConnect: controller.connectSavedDevice,
        ),
      );
      if (selectedBinding == null) return;
    }
    final selectedId =
        selectedBinding?.id ??
        deviceId ??
        controller.connectedDevice?.uuid.toString();
    if (!mounted) return;
    String? selectedName = selectedBinding?.name ?? deviceName;
    if (selectedName == null) {
      for (final binding in controller.authKeyBindings) {
        if (binding.id == selectedId) {
          selectedName = binding.name;
          break;
        }
      }
    }
    final selectedActiveDevice = controller.connectedDevice?.uuid.toString();
    final editsActiveDevice =
        selectedId != null &&
        selectedActiveDevice != null &&
        selectedActiveDevice.toLowerCase() == selectedId.toLowerCase();
    final initial = !showHistory || selectedId == null || editsActiveDevice
        ? controller.authKey
        : await _readAuthKeyForEditor(controller, selectedId);
    if (!mounted) return;
    final value = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _AuthKeyEditDialog(deviceName: selectedName, initialValue: initial),
    );
    if (value == null) return;
    // Editing a historical binding must never replace the live device's
    // in-memory key or trigger a reconnect of that other device. It is only
    // an explicit update to the selected device's saved credential.
    if (selectedBinding != null && !editsActiveDevice) {
      final name = selectedName ?? 'saved device';
      await controller.rememberAuthKeyBinding(
        id: selectedBinding.id,
        name: name,
        key: value,
      );
      return;
    }
    if (!await controller.setAuthKey(value, deviceId: selectedId)) return;
    // An edit for the current authenticated device is an explicit persistence
    // action. First-time connection input is persisted only after f=27.
    if (selectedBinding != null) {
      await controller.rememberAuthKeyBinding(
        id: selectedBinding.id,
        name: selectedName ?? 'saved device',
        key: value,
      );
    }
    if (editsActiveDevice && controller.isConnected) {
      await controller.reconnect();
    }
  }

  Future<String?> _readAuthKeyForEditor(
    DeviceController controller,
    String id,
  ) async {
    try {
      return await controller
          .readAuthKeyFor(id)
          .timeout(const Duration(milliseconds: 600));
    } on Object {
      // Opening the editor must not depend on a platform secure-store call.
      return controller.authKey;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final modules = _pageModules;
    if (modules.isEmpty) return const SizedBox.shrink();
    final selectedIndex = _selectedIndex.clamp(0, modules.length - 1);
    if (selectedIndex != _selectedIndex) _selectedIndex = selectedIndex;
    return Scaffold(
      appBar: AppBar(
        title: _GlobalConnectionStatus(controller: widget.controller),
      ),
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: selectedIndex,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: _selectPage,
              destinations: modules.map(_navigationDestination).toList(),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: modules[selectedIndex].build(_pageContext())),
          ],
        ),
      ),
    );
  }
}

class _AuthKeyBindingPicker extends StatefulWidget {
  const _AuthKeyBindingPicker({
    required this.bindings,
    this.onDelete,
    this.onConnect,
  });

  final List<AuthKeyBinding> bindings;
  final Future<bool> Function(AuthKeyBinding binding)? onDelete;
  final Future<bool> Function(AuthKeyBinding binding)? onConnect;

  @override
  State<_AuthKeyBindingPicker> createState() => _AuthKeyBindingPickerState();
}

class _AuthKeyBindingPickerState extends State<_AuthKeyBindingPicker> {
  AuthKeyBinding? _selected;
  late List<AuthKeyBinding> _bindings;
  String? _deletingBindingId;
  String? _connectingBindingId;

  @override
  void initState() {
    super.initState();
    _bindings = List<AuthKeyBinding>.of(widget.bindings);
  }

  @override
  void didUpdateWidget(covariant _AuthKeyBindingPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bindings, widget.bindings)) {
      _bindings = List<AuthKeyBinding>.of(widget.bindings);
      if (_selected != null &&
          !_bindings.any((binding) => binding.id == _selected!.id)) {
        _selected = null;
      }
    }
  }

  Future<void> _deleteBinding(AuthKeyBinding binding) async {
    final onDelete = widget.onDelete;
    if (onDelete == null || _deletingBindingId != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除已保存设备？'),
        content: Text(
          '将删除' +
              binding.name +
              '在 Wristload 本机保存的 authkey、历史绑定和经典蓝牙身份映射。'
                  '不会删除系统蓝牙配对。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('删除设备'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deletingBindingId = binding.id);
    final deleted = await onDelete(binding);
    if (!mounted) return;
    setState(() {
      _deletingBindingId = null;
      if (deleted) {
        _bindings = _bindings
            .where((candidate) => candidate.id != binding.id)
            .toList(growable: false);
        if (_selected?.id == binding.id) _selected = null;
      }
    });
    if (!deleted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已保存设备未能完全删除，请查看诊断日志。')));
    }
  }

  Future<void> _connectBinding(AuthKeyBinding binding) async {
    final onConnect = widget.onConnect;
    if (onConnect == null ||
        _connectingBindingId != null ||
        _deletingBindingId != null) {
      return;
    }
    setState(() => _connectingBindingId = binding.id);
    final started = await onConnect(binding);
    if (!mounted) return;
    if (started) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _connectingBindingId = null);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法开始连接，请确认蓝牙可用且设备在附近。')));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('设备管理'),
    content: SizedBox(
      width: 420,
      child: _bindings.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: Text('没有已保存设备')),
            )
          : ListView(
              shrinkWrap: true,
              children: _bindings
                  .map(
                    (binding) => ListTile(
                      leading: Radio<AuthKeyBinding>(
                        value: binding,
                        groupValue: _selected,
                        onChanged: (value) => setState(() => _selected = value),
                      ),
                      title: Text(binding.name),
                      subtitle: Text(binding.uuid),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.onDelete != null)
                            IconButton(
                              key: ValueKey(
                                'delete-saved-binding-' + binding.id,
                              ),
                              tooltip: '删除已保存设备',
                              onPressed: _deletingBindingId == null
                                  ? () => _deleteBinding(binding)
                                  : null,
                              icon: _deletingBindingId == binding.id
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.delete_outline),
                            ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                      selected: _selected?.id == binding.id,
                      onTap: () => setState(() => _selected = binding),
                    ),
                  )
                  .toList(growable: false),
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      if (widget.onConnect != null)
        OutlinedButton.icon(
          key: const ValueKey('connect-saved-binding'),
          onPressed:
              _selected == null ||
                  _deletingBindingId != null ||
                  _connectingBindingId != null
              ? null
              : () => _connectBinding(_selected!),
          icon: _connectingBindingId == null
              ? const Icon(Icons.link)
              : const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
          label: const Text('连接'),
        ),
      FilledButton(
        onPressed: _selected == null
            ? null
            : () => Navigator.of(context).pop(_selected),
        child: const Text('修改'),
      ),
    ],
  );
}

class _GlobalConnectionStatus extends StatelessWidget {
  const _GlobalConnectionStatus({required this.controller});

  final DeviceController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final connectedSessions = controller.connectedDeviceSessions;
    final connected = controller.isConnected;
    final connecting = !connected && controller.isConnecting;
    final disconnecting =
        !connected && !connecting && controller.isConnectionBusy;
    final deviceName =
        (controller.connectedDeviceName ??
                controller.connectedProfile?.displayName ??
                '')
            .trim();
    final label = connecting
        ? '正在连接${deviceName.isEmpty ? '' : '：$deviceName'}'
        : disconnecting
        ? '正在断开设备'
        : '设备未连接';

    return Row(
      key: const ValueKey('global-connection-status'),
      mainAxisSize: MainAxisSize.min,
      children: [
        WristloadLogoMark(
          key: const ValueKey('global-brand-logo'),
          dimension: 26,
          color: colors.primary,
        ),
        const SizedBox(width: 8),
        const Text('Wristload'),
        const SizedBox(width: 16),
        if (connectedSessions.isNotEmpty)
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (
                  var index = 0;
                  index < connectedSessions.length;
                  index++
                ) ...[
                  if (index > 0) const SizedBox(width: 18),
                  Flexible(
                    child: _GlobalConnectedDeviceLabel(
                      session: connectedSessions[index],
                      dotKey: index == 0
                          ? const ValueKey('global-connection-status-dot')
                          : ValueKey(
                              'global-connection-status-dot-${connectedSessions[index].id}',
                            ),
                    ),
                  ),
                ],
              ],
            ),
          )
        else ...[
          Container(
            key: const ValueKey('global-connection-status-dot'),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connecting || disconnecting
                  ? colors.tertiary
                  : colors.error,
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }
}

class _GlobalConnectedDeviceLabel extends StatelessWidget {
  const _GlobalConnectedDeviceLabel({
    required this.session,
    required this.dotKey,
  });

  final DeviceSessionView session;
  final Key dotKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = session.name.trim();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: dotKey,
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            name.isEmpty ? '已连接设备' : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _AuthKeyEditDialog extends StatefulWidget {
  const _AuthKeyEditDialog({
    required this.deviceName,
    required this.initialValue,
  });

  final String? deviceName;
  final String? initialValue;

  @override
  State<_AuthKeyEditDialog> createState() => _AuthKeyEditDialogState();
}

class _AuthKeyEditDialogState extends State<_AuthKeyEditDialog> {
  late final TextEditingController _field;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _save() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_field.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.deviceName == null
          ? '修改设备 authkey'
          : '修改 ${widget.deviceName} authkey',
    ),
    content: Form(
      key: _formKey,
      child: TextFormField(
        controller: _field,
        autofocus: true,
        selectAllOnFocus: false,
        keyboardType: TextInputType.visiblePassword,
        textInputAction: TextInputAction.done,
        maxLength: 32,
        autocorrect: false,
        enableSuggestions: false,
        onFieldSubmitted: (_) => _save(),
        decoration: const InputDecoration(
          labelText: 'authkey',
          hintText: '32 位十六进制',
          counterText: '',
          border: OutlineInputBorder(),
        ),
        validator: (text) =>
            RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(text?.trim() ?? '')
            ? null
            : '请输入 32 位十六进制字符',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}

/// Exposes the authkey editor to widget tests without making its state public.
Widget buildAuthKeyEditDialogForTesting({
  String? deviceName,
  String? initialValue,
}) {
  return _AuthKeyEditDialog(deviceName: deviceName, initialValue: initialValue);
}

Widget buildAuthKeyBindingPickerForTesting({
  required List<AuthKeyBinding> bindings,
  Future<bool> Function(AuthKeyBinding binding)? onDelete,
  Future<bool> Function(AuthKeyBinding binding)? onConnect,
}) => _AuthKeyBindingPicker(
  bindings: bindings,
  onDelete: onDelete,
  onConnect: onConnect,
);
