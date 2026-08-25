import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'diagnostic_log_service.dart';

class PerformanceDiagnosticReport {
  const PerformanceDiagnosticReport({
    required this.id,
    required this.trigger,
    required this.createdAt,
    required this.text,
  });

  factory PerformanceDiagnosticReport.fromJson(Map<String, Object?> json) {
    return PerformanceDiagnosticReport(
      id: json['id']?.toString() ?? 'unknown',
      trigger: json['trigger']?.toString() ?? 'unknown',
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
      text: json['text']?.toString() ?? '',
    );
  }

  final String id;
  final String trigger;
  final DateTime createdAt;
  final String text;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'trigger': trigger,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'text': text,
  };
}

class _SlowFrameSample {
  const _SlowFrameSample({
    required this.recordedAt,
    required this.build,
    required this.raster,
    required this.total,
  });

  final DateTime recordedAt;
  final Duration build;
  final Duration raster;
  final Duration total;
}

/// Low-overhead, process-wide RSS and Flutter frame latency monitor.
///
/// All in-memory collections and persisted history are bounded so the
/// diagnostic tool cannot become an unbounded source of memory growth.
class PerformanceDiagnosticService extends ChangeNotifier {
  PerformanceDiagnosticService({
    this.memoryThresholdBytes = 600 * 1024 * 1024,
    this.sampleInterval = const Duration(seconds: 3),
    this.appVersion = '1.0Beta',
  });

  static final instance = PerformanceDiagnosticService();
  static const _reportCooldown = Duration(minutes: 10);
  static const _jankWindow = Duration(seconds: 10);
  static const _heartbeatInterval = Duration(seconds: 1);
  static const _heartbeatDelayThreshold = Duration(milliseconds: 500);
  static const _maxReports = 20;

  final int memoryThresholdBytes;
  final Duration sampleInterval;
  final String appVersion;
  String Function()? stateSnapshotProvider;
  final List<int> _memorySamples = <int>[];
  final List<String> _behaviors = <String>[];
  final List<_SlowFrameSample> _slowFrames = <_SlowFrameSample>[];
  final List<PerformanceDiagnosticReport> _reports =
      <PerformanceDiagnosticReport>[];

  Timer? _memoryTimer;
  Timer? _heartbeatTimer;
  Directory? _reportDirectory;
  bool _started = false;
  bool _disposed = false;
  int _startGeneration = 0;
  int _overThresholdSamples = 0;
  DateTime? _lastMemoryReportAt;
  DateTime? _lastJankReportAt;
  DateTime? _lastHeartbeatAt;
  Duration? _lastHeartbeatDelay;
  String _location = 'application startup';
  String _lastBehavior = 'application started';

  bool get started => _started;
  int get currentRss => ProcessInfo.currentRss;
  String get location => _location;
  List<PerformanceDiagnosticReport> get reports =>
      List<PerformanceDiagnosticReport>.unmodifiable(_reports.reversed);
  PerformanceDiagnosticReport? get latestReport =>
      _reports.isEmpty ? null : _reports.last;

  Future<void> start() async {
    if (_started || _disposed) return;
    final generation = ++_startGeneration;
    _started = true;
    try {
      final support = await getApplicationSupportDirectory();
      _reportDirectory = Directory(
        '${support.path}${Platform.pathSeparator}performance_reports',
      );
      await _reportDirectory!.create(recursive: true);
      await _loadReports();
    } on Object catch (error, stackTrace) {
      appLogger.warning(
        'performance report storage unavailable',
        category: DiagnosticLogCategory.storage,
        fields: <String, Object?>{
          'errorType': error.runtimeType.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
    }
    if (_disposed || !_started || generation != _startGeneration) return;
    WidgetsBinding.instance.addTimingsCallback(_handleFrameTimings);
    _memoryTimer = Timer.periodic(sampleInterval, (_) => _sampleMemory());
    _lastHeartbeatAt = DateTime.now();
    _heartbeatTimer = Timer.periodic(
      _heartbeatInterval,
      (_) => _sampleEventLoopHeartbeat(),
    );
    _sampleMemory();
    recordBehavior('application performance monitor started');
  }

  void recordPage({
    required String id,
    required String route,
    required String label,
  }) {
    _location = '$id ($route) $label';
    recordBehavior('page changed: $_location');
  }

  void recordBehavior(String behavior) {
    if (_disposed) return;
    if (_lastBehavior == behavior) return;
    _lastBehavior = behavior;
    _behaviors.add(
      '${DateTime.now().toIso8601String()}  $_location  $behavior',
    );
    if (_behaviors.length > 80) {
      _behaviors.removeRange(0, _behaviors.length - 80);
    }
  }

  void _sampleMemory() {
    if (_disposed) return;
    final rss = ProcessInfo.currentRss;
    _memorySamples.add(rss);
    if (_memorySamples.length > 120) _memorySamples.removeAt(0);

    if (rss >= memoryThresholdBytes) {
      _overThresholdSamples++;
      if (_overThresholdSamples >= 3 && _cooldownElapsed(_lastMemoryReportAt)) {
        _lastMemoryReportAt = DateTime.now();
        unawaited(
          _createReport(
            trigger: 'memory',
            reason:
                'RSS remained above ${formatBytes(memoryThresholdBytes)} '
                'for three samples',
          ),
        );
      }
    } else {
      _overThresholdSamples = 0;
    }
    if (hasListeners) notifyListeners();
  }

  void _handleFrameTimings(List<FrameTiming> timings) {
    if (_disposed) return;
    final now = DateTime.now();
    var severeFrame = false;
    for (final timing in timings) {
      if (timing.totalSpan < const Duration(milliseconds: 100)) continue;
      _slowFrames.add(
        _SlowFrameSample(
          recordedAt: now,
          build: timing.buildDuration,
          raster: timing.rasterDuration,
          total: timing.totalSpan,
        ),
      );
      severeFrame |= timing.totalSpan >= const Duration(milliseconds: 500);
    }
    _slowFrames.removeWhere(
      (sample) => now.difference(sample.recordedAt) > _jankWindow,
    );
    if ((severeFrame || _slowFrames.length >= 3) &&
        _cooldownElapsed(_lastJankReportAt)) {
      _lastJankReportAt = now;
      unawaited(
        _createReport(
          trigger: 'jank',
          reason: severeFrame
              ? 'a frame exceeded 500 ms'
              : 'three or more frames exceeded 100 ms within 10 seconds',
        ),
      );
    }
  }

  void _sampleEventLoopHeartbeat() {
    if (_disposed || !_started) return;
    final now = DateTime.now();
    final previous = _lastHeartbeatAt;
    _lastHeartbeatAt = now;
    if (previous == null) return;

    final elapsed = now.difference(previous);
    final delay = elapsed - _heartbeatInterval;
    // Ignore app suspension, system sleep, and wall-clock jumps.
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState != null && lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    if (elapsed >= const Duration(seconds: 30) ||
        delay < _heartbeatDelayThreshold ||
        !_cooldownElapsed(_lastJankReportAt)) {
      return;
    }

    _lastHeartbeatDelay = delay;
    _lastJankReportAt = now;
    unawaited(
      _createReport(
        trigger: 'jank',
        reason:
            'Flutter event loop heartbeat was delayed by '
            '${delay.inMilliseconds} ms',
      ),
    );
  }

  bool _cooldownElapsed(DateTime? previous) =>
      previous == null ||
      DateTime.now().difference(previous) >= _reportCooldown;

  Future<void> _createReport({
    required String trigger,
    required String reason,
  }) async {
    if (_disposed || !_started) return;
    final now = DateTime.now();
    final id = now.microsecondsSinceEpoch.toString();
    final allLogs = appLogger.entries;
    final recentLogs = allLogs.length > 40
        ? allLogs.sublist(allLogs.length - 40)
        : allLogs;
    final stateSnapshot = _readStateSnapshot();
    final recentSlowFrames = _slowFrames
        .where((sample) => now.difference(sample.recordedAt) <= _jankWindow)
        .toList(growable: false);
    final slowFrameLines = recentSlowFrames.map(
      (sample) =>
          '${sample.recordedAt.toIso8601String()} '
          'build=${sample.build.inMicroseconds / 1000}ms '
          'raster=${sample.raster.inMicroseconds / 1000}ms '
          'total=${sample.total.inMicroseconds / 1000}ms',
    );
    final reportText =
        (StringBuffer()
              ..writeln('Wristload performance diagnostic report')
              ..writeln('id: $id')
              ..writeln('trigger: $trigger')
              ..writeln('reason: $reason')
              ..writeln('time: ${now.toIso8601String()}')
              ..writeln('location: $_location')
              ..writeln('last behavior: $_lastBehavior')
              ..writeln('current RSS: ${formatBytes(ProcessInfo.currentRss)}')
              ..writeln('peak RSS: ${formatBytes(ProcessInfo.maxRss)}')
              ..writeln(
                'memory threshold: ${formatBytes(memoryThresholdBytes)}',
              )
              ..writeln(
                'memory samples: ${_memorySamples.map(formatBytes).join(', ')}',
              )
              ..writeln()
              ..writeln('[slow frames in 10-second window]')
              ..writeln(
                slowFrameLines.isEmpty ? 'none' : slowFrameLines.join('\n'),
              )
              ..writeln(
                'latest event-loop heartbeat delay: '
                '${_lastHeartbeatDelay?.inMilliseconds ?? 0} ms',
              )
              ..writeln()
              ..writeln('[runtime environment]')
              ..writeln('application version: $appVersion')
              ..writeln('OS: ${Platform.operatingSystem}')
              ..writeln('OS version: ${Platform.operatingSystemVersion}')
              ..writeln('Dart: ${Platform.version.split(' ').first}')
              ..writeln(
                'build mode: ${kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug')}',
              )
              ..writeln('locale: ${Platform.localeName}')
              ..writeln('logical processors: ${Platform.numberOfProcessors}')
              ..writeln(_renderingEnvironmentLines().join('\n'))
              ..writeln()
              ..writeln('[application state]')
              ..writeln(
                stateSnapshot?.trim().isNotEmpty == true
                    ? stateSnapshot
                    : 'unavailable',
              )
              ..writeln()
              ..writeln('[recent behavior]')
              ..writeln(_behaviors.isEmpty ? 'none' : _behaviors.join('\n'))
              ..writeln('[recent redacted diagnostic log]')
              ..writeln(recentLogs.map(_formatReportLogEntry).join('\n')))
            .toString()
            .trimRight();
    final report = PerformanceDiagnosticReport(
      id: id,
      trigger: trigger,
      createdAt: now,
      text: reportText,
    );
    _reports.add(report);
    if (_reports.length > _maxReports) {
      _reports.removeRange(0, _reports.length - _maxReports);
    }

    final directory = _reportDirectory;
    if (directory != null) {
      try {
        await File(
          '${directory.path}${Platform.pathSeparator}$id.json',
        ).writeAsString(jsonEncode(report.toJson()), flush: true);
        await _trimReportFiles(directory);
      } on Object catch (error) {
        appLogger.warning(
          'performance report write failed',
          category: DiagnosticLogCategory.storage,
          fields: <String, Object?>{'errorType': error.runtimeType.toString()},
        );
      }
    }
    if (_disposed || !_started) return;
    appLogger.error(
      'performance anomaly report generated',
      category: DiagnosticLogCategory.runtime,
      fields: <String, Object?>{'trigger': trigger, 'reportId': id},
    );
    if (_disposed || !_started) return;
    await _showWindowsNotification(
      trigger == 'memory' ? '内存占用异常' : '界面卡顿异常',
      '已生成性能诊断报告，可在“关于”页面查看。',
    );
    if (!_disposed && hasListeners) notifyListeners();
  }

  String? _readStateSnapshot() {
    try {
      return stateSnapshotProvider?.call();
    } on Object catch (error) {
      return 'snapshot unavailable (${error.runtimeType})';
    }
  }

  List<String> _renderingEnvironmentLines() {
    try {
      final views = WidgetsBinding.instance.platformDispatcher.views.toList();
      final lines = <String>['Flutter view count: ${views.length}'];
      for (var index = 0; index < views.length; index++) {
        final view = views[index];
        final physicalSize = view.physicalSize;
        final ratio = view.devicePixelRatio;
        final logicalWidth = ratio == 0 ? 0 : physicalSize.width / ratio;
        final logicalHeight = ratio == 0 ? 0 : physicalSize.height / ratio;
        lines.add(
          'view[$index]: physical=${physicalSize.width.toStringAsFixed(0)}x'
          '${physicalSize.height.toStringAsFixed(0)} px, '
          'logical=${logicalWidth.toStringAsFixed(1)}x'
          '${logicalHeight.toStringAsFixed(1)}, '
          'devicePixelRatio=${ratio.toStringAsFixed(2)}',
        );
      }
      return lines;
    } on Object catch (error) {
      return <String>[
        'Flutter rendering environment: unavailable '
            '(${error.runtimeType})',
      ];
    }
  }

  String _formatReportLogEntry(DiagnosticLogEntry entry) {
    // Protocol fields such as wireHex are intentionally omitted from the
    // portable report. The message has already passed the central redactor.
    return '${entry.timestamp.toLocal().toIso8601String()}  '
        '${entry.level.label.padRight(7)} [${entry.scope}] '
        '${entry.component}  ${entry.message}';
  }

  Future<void> _loadReports() async {
    final directory = _reportDirectory;
    if (directory == null || !await directory.exists()) return;
    final files =
        (await directory
              .list()
              .where(
                (entity) => entity is File && entity.path.endsWith('.json'),
              )
              .toList())
          ..sort((a, b) => a.path.compareTo(b.path));
    final start = files.length > _maxReports ? files.length - _maxReports : 0;
    for (final entity in files.skip(start)) {
      try {
        final decoded = jsonDecode(await File(entity.path).readAsString());
        if (decoded is Map) {
          _reports.add(
            PerformanceDiagnosticReport.fromJson(
              Map<String, Object?>.from(decoded),
            ),
          );
        }
      } on Object {
        // A damaged historical report must not disable monitoring.
      }
    }
    if (!_disposed && hasListeners) notifyListeners();
  }

  Future<void> _trimReportFiles(Directory directory) async {
    final files =
        (await directory
              .list()
              .where(
                (entity) => entity is File && entity.path.endsWith('.json'),
              )
              .toList())
          ..sort((a, b) => a.path.compareTo(b.path));
    final excess = files.length - _maxReports;
    if (excess <= 0) return;
    for (final entity in files.take(excess)) {
      await File(entity.path).delete();
    }
  }

  Future<void> _showWindowsNotification(String title, String body) async {
    if (!Platform.isWindows) return;
    try {
      await const MethodChannel(
        'wristload/windows_notifications',
      ).invokeMethod<void>('show', <String, String>{
        'title': title,
        'body': body,
      });
    } on Object catch (error) {
      appLogger.warning(
        'Windows performance notification failed',
        category: DiagnosticLogCategory.ui,
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
    }
  }

  Future<void> shutdown() async {
    if (!_started) return;
    _startGeneration++;
    _started = false;
    _memoryTimer?.cancel();
    _memoryTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _lastHeartbeatAt = null;
    WidgetsBinding.instance.removeTimingsCallback(_handleFrameTimings);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }

  static String formatBytes(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
