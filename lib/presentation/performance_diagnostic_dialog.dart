import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/performance_diagnostic_service.dart';

Future<void> openPerformanceDiagnosticDialog(
  BuildContext context,
  PerformanceDiagnosticService service,
) {
  service.recordBehavior('performance diagnostic viewer opened');
  return showDialog<void>(
    context: context,
    builder: (_) => _PerformanceDiagnosticDialog(service: service),
  );
}

class _PerformanceDiagnosticDialog extends StatefulWidget {
  const _PerformanceDiagnosticDialog({required this.service});

  final PerformanceDiagnosticService service;

  @override
  State<_PerformanceDiagnosticDialog> createState() =>
      _PerformanceDiagnosticDialogState();
}

class _PerformanceDiagnosticDialogState
    extends State<_PerformanceDiagnosticDialog> {
  PerformanceDiagnosticReport? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.service.latestReport;
    widget.service.addListener(_refresh);
  }

  void _refresh() {
    if (!mounted) return;
    setState(() => _selected ??= widget.service.latestReport);
  }

  @override
  void dispose() {
    widget.service.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _copy() async {
    final report = _selected;
    if (report == null) return;
    await Clipboard.setData(ClipboardData(text: report.text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('性能诊断报告已复制')));
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final reports = service.reports;
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.speed_outlined),
          SizedBox(width: 12),
          Text('性能诊断'),
        ],
      ),
      content: SizedBox(
        width: 820,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '监控状态：${service.started ? '运行中' : '已停止'}  '
              '当前 RSS：${PerformanceDiagnosticService.formatBytes(service.currentRss)}  '
              '阈值：${PerformanceDiagnosticService.formatBytes(service.memoryThresholdBytes)}',
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 230,
                    child: reports.isEmpty
                        ? const Center(child: Text('尚未生成异常报告'))
                        : ListView.builder(
                            itemCount: reports.length,
                            itemBuilder: (context, index) {
                              final report = reports[index];
                              return ListTile(
                                selected: _selected?.id == report.id,
                                leading: Icon(
                                  report.trigger == 'memory'
                                      ? Icons.memory_outlined
                                      : Icons.speed_outlined,
                                ),
                                title: Text(
                                  report.trigger == 'memory' ? '内存异常' : '卡顿异常',
                                ),
                                subtitle: Text(
                                  report.createdAt.toLocal().toIso8601String(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => setState(() => _selected = report),
                              );
                            },
                          ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      color: colors.surfaceContainerLow,
                      child: SingleChildScrollView(
                        child: SelectableText(
                          _selected?.text ??
                              '监控会在内存连续三次超过 600 MiB，或检测到异常慢帧时自动生成报告，并调用 Windows 系统通知。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(fontFamily: 'monospace', height: 1.5),
                        ),
                      ),
                    ),
                  ),
                ],
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
          onPressed: _selected == null ? null : _copy,
          icon: const Icon(Icons.copy_all_outlined),
          label: const Text('复制报告'),
        ),
      ],
    );
  }
}
