import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/domain/protocol/device_log_transfer.dart';
import 'package:wristload/domain/protocol/mass_transfer.dart' show crc32;

void main() {
  test('parses and reassembles official six-byte log segments', () {
    final assembler = DeviceLogAssembler();
    final first = DeviceLogSegment.parse([
      0,
      oneTrackLogCommand,
      2,
      0,
      1,
      0,
      1,
      2,
    ]);
    final second = DeviceLogSegment.parse([
      0,
      oneTrackLogCommand,
      2,
      0,
      2,
      0,
      3,
      4,
    ]);

    expect(assembler.add(first), isNull);
    expect(assembler.total, 2);
    expect(assembler.received, 1);
    expect(assembler.add(second), [1, 2, 3, 4]);
    expect(assembler.received, 0);
  });

  test('rejects missing or reordered log segments', () {
    final assembler = DeviceLogAssembler();
    final second = DeviceLogSegment.parse([0, deviceLogCommand, 2, 0, 2, 0, 1]);

    expect(() => assembler.add(second), throwsA(isA<FormatException>()));
    expect(assembler.received, 0);
  });

  test('validates CRC32 and extracts device path and file bytes', () {
    final path = utf8.encode('/data/usage_stats/sample');
    final content = <int>[0xde, 0xad, 0xbe, 0xef];
    final body = <int>[path.length, ...path, 0, 0, 0, 0, 0, ...content];
    final checksum = crc32(body);
    final merged = <int>[
      ...body,
      checksum & 0xff,
      (checksum >> 8) & 0xff,
      (checksum >> 16) & 0xff,
      (checksum >> 24) & 0xff,
    ];

    final parsed = DeviceLogFilePayload.parse(merged);
    expect(parsed.devicePath, '/data/usage_stats/sample');
    expect(parsed.bytes, content);

    merged.last ^= 0xff;
    expect(
      () => DeviceLogFilePayload.parse(merged),
      throwsA(isA<FormatException>()),
    );
  });

  test('sanitizes device paths before host filesystem use', () {
    expect(safeDeviceLogPathComponents('/data/../usage:stats/log?.txt'), [
      'data',
      'usage_stats',
      'log_.txt',
    ]);
  });
}
