import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';

import '../application/device_controller.dart';
import '../domain/install_preference_store.dart';

Future<void> openDeviceEnvironmentDetailsDialog(
  BuildContext context, {
  required DeviceController controller,
  required String appVersion,
  required Color themeSeedColor,
  required InstallPreference preferredInstallTarget,
  required bool floatingInstallWindowEnabled,
  required bool autoOpenDiagnosticLog,
}) async {
  final media = MediaQuery.of(context);
  final theme = Theme.of(context);
  final report = await _buildEnvironmentReport(
    media: media,
    theme: theme,
    controller: controller,
    appVersion: appVersion,
    themeSeedColor: themeSeedColor,
    preferredInstallTarget: preferredInstallTarget,
    floatingInstallWindowEnabled: floatingInstallWindowEnabled,
    autoOpenDiagnosticLog: autoOpenDiagnosticLog,
  );
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => _DeviceEnvironmentDetailsDialog(report: report),
  );
}

class _DeviceEnvironmentDetailsDialog extends StatelessWidget {
  const _DeviceEnvironmentDetailsDialog({required this.report});

  final String report;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: report));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('设备信息详情已复制')));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.monitor_heart_outlined),
          SizedBox(width: 12),
          Text('设备信息详情'),
        ],
      ),
      content: SizedBox(
        width: 720,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '以下信息不包含 authkey、设备地址、用户名或文件路径，可直接提供给开发者。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    report,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      height: 1.55,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: () => _copy(context),
          icon: const Icon(Icons.copy_all_outlined),
          label: const Text('复制全部'),
        ),
      ],
    );
  }
}

Future<String> _buildEnvironmentReport({
  required MediaQueryData media,
  required ThemeData theme,
  required DeviceController controller,
  required String appVersion,
  required Color themeSeedColor,
  required InstallPreference preferredInstallTarget,
  required bool floatingInstallWindowEnabled,
  required bool autoOpenDiagnosticLog,
}) async {
  List<Display> displays = const [];
  String? displayError;
  try {
    displays = await screenRetriever.getAllDisplays();
  } on Object catch (error) {
    displayError = error.runtimeType.toString();
  }

  final logicalSize = media.size;
  final physicalWidth = logicalSize.width * media.devicePixelRatio;
  final physicalHeight = logicalSize.height * media.devicePixelRatio;
  final buffer = StringBuffer()
    ..writeln('Wristload 设备信息详情')
    ..writeln('生成时间: ${DateTime.now().toIso8601String()}')
    ..writeln()
    ..writeln('[应用与运行时]')
    ..writeln('应用版本: $appVersion')
    ..writeln('构建模式: ${_buildMode()}')
    ..writeln('Dart: ${Platform.version.split(' ').first}')
    ..writeln('Flutter 平台: ${defaultTargetPlatform.name}')
    ..writeln('Material 3: ${theme.useMaterial3}')
    ..writeln()
    ..writeln('[系统与性能]')
    ..writeln('操作系统: ${Platform.operatingSystem}')
    ..writeln('系统版本: ${Platform.operatingSystemVersion}')
    ..writeln('处理器架构: ${_abiLabel(Abi.current())}')
    ..writeln('逻辑处理器: ${Platform.numberOfProcessors}')
    ..writeln('当前内存占用: ${_formatBytes(ProcessInfo.currentRss)}')
    ..writeln('峰值内存占用: ${_formatBytes(ProcessInfo.maxRss)}')
    ..writeln('区域设置: ${Platform.localeName}')
    ..writeln('时区: ${DateTime.now().timeZoneName}')
    ..writeln('时区偏移: ${DateTime.now().timeZoneOffset}')
    ..writeln()
    ..writeln('[窗口与渲染]')
    ..writeln(
      '逻辑窗口: ${logicalSize.width.toStringAsFixed(1)} x ${logicalSize.height.toStringAsFixed(1)}',
    )
    ..writeln('物理窗口: ${physicalWidth.round()} x ${physicalHeight.round()}')
    ..writeln('设备像素比: ${media.devicePixelRatio.toStringAsFixed(3)}')
    ..writeln('文字缩放: ${media.textScaler.scale(1).toStringAsFixed(3)}')
    ..writeln('平台亮度: ${media.platformBrightness.name}')
    ..writeln('主题亮度: ${theme.brightness.name}')
    ..writeln('主题种子色: ${_colorHex(themeSeedColor)}')
    ..writeln('主题主色: ${_colorHex(theme.colorScheme.primary)}')
    ..writeln('高对比度: ${media.highContrast}')
    ..writeln('粗体文字: ${media.boldText}')
    ..writeln('禁用动画: ${media.disableAnimations}')
    ..writeln('反转颜色: ${media.invertColors}')
    ..writeln('无障碍导航: ${media.accessibleNavigation}')
    ..writeln('24 小时制: ${media.alwaysUse24HourFormat}')
    ..writeln('导航模式: ${media.navigationMode.name}')
    ..writeln('安全区: ${_edgeInsets(media.padding)}')
    ..writeln('系统遮挡: ${_edgeInsets(media.viewPadding)}')
    ..writeln('输入法遮挡: ${_edgeInsets(media.viewInsets)}')
    ..writeln('GPU/渲染器名称: Flutter 公共 API 未提供')
    ..writeln()
    ..writeln('[显示器]');

  if (displays.isEmpty) {
    buffer.writeln(displayError == null ? '未发现显示器信息' : '读取失败: $displayError');
  } else {
    buffer.writeln('显示器数量: ${displays.length}');
    for (var index = 0; index < displays.length; index++) {
      final display = displays[index];
      buffer
        ..writeln('显示器 ${index + 1}: ${display.name ?? '未命名'}')
        ..writeln(
          '  逻辑尺寸: ${display.size.width.toStringAsFixed(0)} x ${display.size.height.toStringAsFixed(0)}',
        )
        ..writeln('  缩放系数: ${display.scaleFactor ?? '未知'}')
        ..writeln(
          '  可用区域: ${display.visibleSize == null ? '未知' : '${display.visibleSize!.width.toStringAsFixed(0)} x ${display.visibleSize!.height.toStringAsFixed(0)}'}',
        );
    }
  }

  buffer
    ..writeln()
    ..writeln('[应用配置]')
    ..writeln('首选安装目标: ${preferredInstallTarget.name}')
    ..writeln('悬浮安装窗口: $floatingInstallWindowEnabled')
    ..writeln('启动时打开诊断日志: $autoOpenDiagnosticLog')
    ..writeln('连接模式: ${controller.connectionMode.name}')
    ..writeln('分片间隔: ${controller.segmentIntervalMs} ms')
    ..writeln('Mass 窗口大小: ${controller.massWindowSize}')
    ..writeln('RPK 大小上限: ${_formatBytes(controller.rpkMaxPackageBytes)}')
    ..writeln('自动时间同步: ${controller.autoTimeSync}')
    ..writeln('资源安装路由: ${controller.resourceInstallTargetPolicy.mode.name}')
    ..writeln()
    ..writeln('[当前状态]')
    ..writeln('蓝牙状态: ${controller.bluetoothState.name}')
    ..writeln('正在扫描: ${controller.isScanning}')
    ..writeln('正在连接: ${controller.isConnecting}')
    ..writeln('连接已验证: ${controller.isConnected}')
    ..writeln('应用会话就绪: ${controller.sessionReady}')
    ..writeln('安装进行中: ${controller.installInProgress}')
    ..writeln('时间同步进行中: ${controller.timeSyncInProgress}')
    ..writeln('状态刷新进行中: ${controller.statusRefreshInProgress}')
    ..writeln('设备型号: ${controller.connectedProfile?.displayName ?? '未连接'}')
    ..writeln('固件版本: ${controller.connectedFirmwareVersion ?? '未知'}');

  return buffer.toString().trimRight();
}

String _buildMode() {
  if (kReleaseMode) return 'release';
  if (kProfileMode) return 'profile';
  return 'debug';
}

String _abiLabel(Abi abi) {
  final value = abi.toString();
  final separator = value.lastIndexOf('.');
  return separator < 0 ? value : value.substring(separator + 1);
}

String _formatBytes(int bytes) {
  const mib = 1024 * 1024;
  if (bytes >= 1024 * mib) {
    return '${(bytes / (1024 * mib)).toStringAsFixed(2)} GiB';
  }
  return '${(bytes / mib).toStringAsFixed(1)} MiB';
}

String _colorHex(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

String _edgeInsets(EdgeInsets value) =>
    'L${value.left.toStringAsFixed(1)} T${value.top.toStringAsFixed(1)} '
    'R${value.right.toStringAsFixed(1)} B${value.bottom.toStringAsFixed(1)}';
