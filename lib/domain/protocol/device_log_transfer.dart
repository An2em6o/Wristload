library;

import 'dart:convert';
import 'dart:typed_data';

import 'mass_transfer.dart' show crc32;

const int deviceLogVersion = 0;
const int deviceLogCommand = 129;
const int oneTrackLogCommand = 130;
const int deviceLogSegmentHeaderLength = 6;
const int deviceLogFileReservedHeaderLength = 5;
const int deviceLogCrcLength = 4;

class DeviceLogSegment {
  const DeviceLogSegment({
    required this.command,
    required this.total,
    required this.sequence,
    required this.data,
  });

  final int command;
  final int total;
  final int sequence;
  final Uint8List data;

  static bool looksLike(List<int> bytes) =>
      bytes.length >= deviceLogSegmentHeaderLength &&
      bytes[0] == deviceLogVersion &&
      (bytes[1] == deviceLogCommand || bytes[1] == oneTrackLogCommand);

  static DeviceLogSegment parse(List<int> bytes) {
    if (!looksLike(bytes)) {
      throw const FormatException('不是受支持的设备日志分片');
    }
    final total = bytes[2] | (bytes[3] << 8);
    final sequence = bytes[4] | (bytes[5] << 8);
    if (total <= 0 || sequence <= 0 || sequence > total) {
      throw FormatException('设备日志分片序号无效：$sequence/$total');
    }
    return DeviceLogSegment(
      command: bytes[1],
      total: total,
      sequence: sequence,
      data: Uint8List.fromList(bytes.sublist(deviceLogSegmentHeaderLength)),
    );
  }
}

class DeviceLogAssembler {
  DeviceLogAssembler({this.maxBytes = 64 * 1024 * 1024});

  final int maxBytes;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int _command = 0;
  int _total = 0;
  int _received = 0;
  int _receivedBytes = 0;

  int get total => _total;
  int get received => _received;
  int get receivedBytes => _receivedBytes;

  Uint8List? add(DeviceLogSegment segment) {
    if (_received == 0) {
      _command = segment.command;
      _total = segment.total;
    } else if (_command != segment.command || _total != segment.total) {
      reset();
      throw const FormatException('设备日志分片类型或总数在传输中发生变化');
    }
    if (segment.sequence != _received + 1) {
      final expected = _received + 1;
      reset();
      throw FormatException('设备日志分片不连续：收到 ${segment.sequence}，预期 $expected');
    }
    if (_receivedBytes + segment.data.length > maxBytes) {
      reset();
      throw FormatException('单个设备日志文件超过 $maxBytes 字节限制');
    }

    _buffer.add(segment.data);
    _received = segment.sequence;
    _receivedBytes += segment.data.length;
    if (_received != _total) return null;

    final completed = _buffer.takeBytes();
    _command = 0;
    _total = 0;
    _received = 0;
    _receivedBytes = 0;
    return completed;
  }

  void reset() {
    _buffer.clear();
    _command = 0;
    _total = 0;
    _received = 0;
    _receivedBytes = 0;
  }
}

class DeviceLogFilePayload {
  const DeviceLogFilePayload({required this.devicePath, required this.bytes});

  final String devicePath;
  final Uint8List bytes;

  static DeviceLogFilePayload parse(List<int> merged) {
    if (merged.length <
        1 + deviceLogFileReservedHeaderLength + deviceLogCrcLength) {
      throw const FormatException('设备日志文件封装长度不足');
    }

    final bodyLength = merged.length - deviceLogCrcLength;
    final expectedCrc =
        merged[bodyLength] |
        (merged[bodyLength + 1] << 8) |
        (merged[bodyLength + 2] << 16) |
        (merged[bodyLength + 3] << 24);
    final actualCrc = crc32(merged.sublist(0, bodyLength));
    if (actualCrc != expectedCrc) {
      throw FormatException(
        '设备日志 CRC32 校验失败：expected=0x${expectedCrc.toRadixString(16).padLeft(8, '0')} '
        'actual=0x${actualCrc.toRadixString(16).padLeft(8, '0')}',
      );
    }

    final pathLength = merged[0];
    final contentOffset = 1 + pathLength + deviceLogFileReservedHeaderLength;
    if (pathLength == 0 || contentOffset > bodyLength) {
      throw const FormatException('设备日志文件路径长度无效');
    }
    final pathBytes = merged.sublist(1, 1 + pathLength);
    final devicePath = utf8.decode(pathBytes, allowMalformed: false);
    if (devicePath.trim().isEmpty || devicePath.contains('\u0000')) {
      throw const FormatException('设备日志文件路径为空或包含 NUL');
    }

    return DeviceLogFilePayload(
      devicePath: devicePath,
      bytes: Uint8List.fromList(merged.sublist(contentOffset, bodyLength)),
    );
  }
}

/// Converts an absolute device path into safe path components below an export
/// directory. Device paths are data and must never be used as host paths.
List<String> safeDeviceLogPathComponents(String devicePath) {
  final parts = devicePath
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty && part != '.' && part != '..')
      .map(
        (part) => part.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim(),
      )
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) {
    throw const FormatException('设备日志文件路径没有安全的文件名');
  }
  return parts;
}
