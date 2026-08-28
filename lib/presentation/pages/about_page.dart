import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/device_controller.dart';
import '../../application/performance_diagnostic_service.dart';
import '../../domain/install_preference_store.dart';
import '../device_environment_details_dialog.dart';
import '../oobe_logo_animation.dart';
import '../page_module.dart';
import '../performance_diagnostic_dialog.dart';

const wristloadPage = WristloadPageModule(
  id: 'about',
  route: '/about',
  label: '关于',
  icon: Icons.info_outline,
  selectedIcon: Icons.info,
  order: 100,
  build: _buildAboutPage,
);

const _projectUrl = 'https://github.com/an2em6o/Wristload';
const _issuesUrl = 'https://github.com/an2em6o/Wristload/issues';
const _appVersion = '1.0Beta';

Widget _buildAboutPage(WristloadPageContext context) => AboutPage(
  controller: context.controller,
  preferredInstallTarget: context.preferredInstallTarget,
  floatingInstallWindowEnabled: context.floatingInstallWindowEnabled,
  autoOpenDiagnosticLog: context.autoOpenDiagnosticLog,
  themeSeedColor: context.themeSeedColor,
  tianyiBlueUnlocked: context.tianyiBlueUnlocked,
  onUnlockTianyiBlue: context.onUnlockTianyiBlue,
  performanceDiagnostics: context.performanceDiagnostics,
);

class AboutPage extends StatefulWidget {
  const AboutPage({
    required this.controller,
    required this.preferredInstallTarget,
    required this.floatingInstallWindowEnabled,
    required this.autoOpenDiagnosticLog,
    required this.themeSeedColor,
    required this.tianyiBlueUnlocked,
    required this.onUnlockTianyiBlue,
    required this.performanceDiagnostics,
    super.key,
  });

  final DeviceController controller;
  final InstallPreference preferredInstallTarget;
  final bool floatingInstallWindowEnabled;
  final bool autoOpenDiagnosticLog;
  final Color themeSeedColor;
  final bool tianyiBlueUnlocked;
  final AsyncCallback onUnlockTianyiBlue;
  final PerformanceDiagnosticService performanceDiagnostics;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static const _requiredVersionTaps = 5;

  int _versionTapCount = 0;
  bool _unlocking = false;

  Future<void> _openDeviceEnvironmentDetails() =>
      openDeviceEnvironmentDetailsDialog(
        context,
        controller: widget.controller,
        appVersion: _appVersion,
        themeSeedColor: widget.themeSeedColor,
        preferredInstallTarget: widget.preferredInstallTarget,
        floatingInstallWindowEnabled: widget.floatingInstallWindowEnabled,
        autoOpenDiagnosticLog: widget.autoOpenDiagnosticLog,
      );

  Future<void> _handleVersionTap() async {
    if (widget.tianyiBlueUnlocked || _unlocking) return;
    _versionTapCount++;
    if (_versionTapCount < _requiredVersionTaps) return;

    _unlocking = true;
    try {
      await widget.onUnlockTianyiBlue();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('天依蓝主题已解锁')));
    } finally {
      _unlocking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const version = _appVersion;
    final buildDate = executableBuildDate();

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('关于', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 28),
            _Hero(version: version),
            const SizedBox(height: 28),
            _SectionHeader(
              title: '版本信息',
              action: TextButton(
                onPressed: () => _copyVersion(context, version, buildDate),
                child: const Text('复制版本信息'),
              ),
            ),
            const SizedBox(height: 12),
            _VersionDetails(
              version: version,
              buildDate: buildDate,
              onVersionTap: _handleVersionTap,
            ),
            const SizedBox(height: 28),
            const _SectionHeader(title: '项目与支持'),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                const repository = _SupportTile(
                  icon: Icons.code,
                  title: '源代码仓库',
                  subtitle: 'GitHub · Wristload',
                  url: _projectUrl,
                );
                const issues = _SupportTile(
                  icon: Icons.error_outline,
                  title: '问题反馈',
                  url: _issuesUrl,
                );
                final deviceDetails = _SupportTile(
                  icon: Icons.monitor_heart_outlined,
                  title: '设备信息详情',
                  onTap: _openDeviceEnvironmentDetails,
                );
                final performanceDetails = _SupportTile(
                  icon: Icons.speed_outlined,
                  title: '性能诊断',
                  onTap: () => openPerformanceDiagnosticDialog(
                    context,
                    widget.performanceDiagnostics,
                  ),
                );
                if (constraints.maxWidth < 680) {
                  return Column(
                    children: [
                      repository,
                      const SizedBox(height: 12),
                      issues,
                      const SizedBox(height: 12),
                      deviceDetails,
                      const SizedBox(height: 12),
                      performanceDetails,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Expanded(child: repository),
                    const SizedBox(width: 12),
                    const Expanded(child: issues),
                    const SizedBox(width: 12),
                    Expanded(child: deviceDetails),
                    const SizedBox(width: 12),
                    Expanded(child: performanceDetails),
                  ],
                );
              },
            ),
            const SizedBox(height: 28),
            const _SectionHeader(title: '开发者'),
            const SizedBox(height: 12),
            const _DevelopersSection(),
            const SizedBox(height: 28),
            const _LegalNotice(),
          ],
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Material(
      color: colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          final logo = Container(
            width: 112,
            height: 112,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(26),
            ),
            child: WristloadLogoMark(
              dimension: 92,
              color: const Color(0xFF66CCFF),
            ),
          );
          final identity = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: compact
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              Text('Wristload', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                '版本 $version',
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          );
          final projectButton = OutlinedButton.icon(
            onPressed: () => unawaited(_openExternal(context, _projectUrl)),
            icon: const Icon(Icons.open_in_new),
            label: const Text('项目主页'),
          );
          if (compact) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  logo,
                  const SizedBox(height: 20),
                  identity,
                  const SizedBox(height: 20),
                  projectButton,
                ],
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Row(
              children: [
                logo,
                const SizedBox(width: 24),
                Expanded(child: identity),
                const SizedBox(width: 24),
                projectButton,
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
        if (action != null) action!,
      ],
    );
  }
}

class _VersionDetails extends StatelessWidget {
  const _VersionDetails({
    required this.version,
    required this.buildDate,
    required this.onVersionTap,
  });

  final String version;
  final String buildDate;
  final VoidCallback onVersionTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final vertical = constraints.maxWidth < 520;
        final versionItem = _VersionItem(
          label: '应用版本',
          value: version,
          onTap: onVersionTap,
        );
        final dateItem = _VersionItem(label: '构建日期', value: buildDate);
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: vertical
              ? Column(
                  children: [versionItem, const Divider(height: 1), dateItem],
                )
              : IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: versionItem),
                      const VerticalDivider(width: 1),
                      Expanded(child: dateItem),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

class _VersionItem extends StatelessWidget {
  const _VersionItem({required this.label, required this.value, this.onTap});

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: onTap == null ? null : const ValueKey('about-app-version'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(value, style: theme.textTheme.titleSmall),
          ],
        ),
      ),
    );
  }
}

class _SupportTile extends StatelessWidget {
  const _SupportTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.url,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? url;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Material(
      color: colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap:
            onTap ??
            (url == null
                ? null
                : () => unawaited(_openExternal(context, url!))),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 92),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: colorScheme.onSurface),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      if (subtitle case final subtitle?) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DevelopersSection extends StatelessWidget {
  const _DevelopersSection();

  @override
  Widget build(BuildContext context) {
    const liangYi = _DeveloperCard(
      name: '梁逸',
      role: 'Devloper · Designer',
      avatarAsset: 'assets/developers/liang-yi.png',
    );
    const ikunCxkpro = _DeveloperCard(
      name: 'IKUN-CXKPRO',
      role: 'Devloper',
      avatarAsset: 'assets/developers/ikun-cxkpro.png',
    );
    const pengchengkai = _DeveloperCard(
      name: 'pengchegnkai',
      role: 'Devloper',
      avatarAsset: 'assets/developers/pengchengkai.jpeg',
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 680) {
          return const Column(
            children: [
              liangYi,
              SizedBox(height: 12),
              ikunCxkpro,
              SizedBox(height: 12),
              pengchengkai,
            ],
          );
        }
        return const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: liangYi),
            SizedBox(width: 12),
            Expanded(child: ikunCxkpro),
            SizedBox(width: 12),
            Expanded(child: pengchengkai),
          ],
        );
      },
    );
  }
}

class _DeveloperCard extends StatelessWidget {
  const _DeveloperCard({
    required this.name,
    required this.role,
    this.avatarAsset,
  });

  final String name;
  final String role;
  final String? avatarAsset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: colors.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 112),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(
            children: [
              if (avatarAsset != null)
                ClipOval(
                  child: Image.asset(
                    avatarAsset!,
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.high,
                  ),
                )
              else
                CircleAvatar(
                  radius: 36,
                  backgroundColor: colors.primaryContainer,
                  child: Text(
                    name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      role,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LegalNotice extends StatelessWidget {
  const _LegalNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.shield_outlined, color: colorScheme.onSurface),
            const SizedBox(width: 16),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '非官方社区工具。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(
                      text:
                          'Wristload 与 Xiaomi、小米集团及其关联公司无隶属或背书关系。'
                          '设备名称和商标归其各自权利人所有。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String executableBuildDate({String? executablePath}) {
  try {
    final date = File(
      executablePath ?? Platform.resolvedExecutable,
    ).lastModifiedSync().toLocal();
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  } on Object {
    return '未知';
  }
}

Future<void> _copyVersion(
  BuildContext context,
  String version,
  String buildDate,
) async {
  await Clipboard.setData(
    ClipboardData(text: 'Wristload $version · $buildDate'),
  );
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: Text('版本信息已复制')));
}

Future<void> _openExternal(BuildContext context, String url) async {
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [
        url,
      ], mode: ProcessStartMode.detached);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [url], mode: ProcessStartMode.detached);
      return;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
      return;
    }
  } on Object {
    // Copying the URL below keeps the action useful when no opener exists.
  }
  await Clipboard.setData(ClipboardData(text: url));
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: Text('无法打开默认浏览器，链接已复制')));
}
