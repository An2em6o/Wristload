/// authkey 的平台安全存储边界。
/// Windows 使用 DPAPI，Android 使用 Android Keystore，macOS 使用 Keychain；
/// Linux 使用 Secret Service（libsecret，如 GNOME Keyring / KWallet）；
/// 不会降级为普通文本文件。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../application/diagnostic_log_service.dart';

class AuthKeyStore {
  static const _channel = MethodChannel('wristload/secure_store');

  /// Linux 后端：Secret Service。键名与 Android 端一致
  /// （`authkey` + `authkey_device_<sha256(id)>`）。
  static const _linuxStorage = FlutterSecureStorage();
  static const _linuxAuthKeyPreference = 'authkey';

  String _linuxDeviceKey(String id) {
    final digest = sha256.convert(utf8.encode(id)).toString();
    return 'authkey_device_$digest';
  }

  Future<String?> read() {
    if (_isLinux) {
      return _linuxRead(_linuxAuthKeyPreference);
    }
    if (!_supported) {
      appLogger.debug('安全存储读取跳过：平台不支持', category: DiagnosticLogCategory.security);
      return Future.value(null);
    }
    appLogger.trace('安全存储读取开始', category: DiagnosticLogCategory.security);
    return _channel.invokeMethod<String>('read').then((value) {
      appLogger.debug('安全存储读取完成', category: DiagnosticLogCategory.security, fields: <String, Object?>{'hasValue': value != null});
      return value;
    }, onError: (Object error, StackTrace stackTrace) {
      appLogger.error('安全存储读取失败：$error', category: DiagnosticLogCategory.security, fields: <String, Object?>{'errorType': error.runtimeType.toString()});
      Error.throwWithStackTrace(error, stackTrace);
    });
  }

  Future<void> write(String value) async {
    if (_isLinux) {
      await _linuxWrite(_linuxAuthKeyPreference, value);
      return;
    }
    if (!_supported) return;
    appLogger.trace('安全存储写入开始', category: DiagnosticLogCategory.security, fields: <String, Object?>{'bytes': value.length});
    await _channel.invokeMethod<void>('write', value);
    appLogger.info('安全存储写入完成', category: DiagnosticLogCategory.security);
  }

  Future<void> delete() async {
    if (_isLinux) {
      await _linuxDelete(_linuxAuthKeyPreference);
      return;
    }
    if (!_supported) return;
    appLogger.trace('安全存储删除开始', category: DiagnosticLogCategory.security);
    await _channel.invokeMethod<void>('delete');
    appLogger.info('安全存储删除完成', category: DiagnosticLogCategory.security);
  }

  Future<String?> readFor(String id) {
    if (_isLinux) {
      return _linuxRead(_linuxDeviceKey(id));
    }
    if (!_supported) return Future.value(null);
    return _channel.invokeMethod<String>('readFor', id);
  }

  Future<void> writeFor(String id, String value) async {
    if (_isLinux) {
      await _linuxWrite(_linuxDeviceKey(id), value);
      return;
    }
    if (!_supported) return;
    await _channel.invokeMethod<void>('writeFor', <String, String>{
      'id': id,
      'value': value,
    });
  }

  Future<void> deleteFor(String id) async {
    if (_isLinux) {
      await _linuxDelete(_linuxDeviceKey(id));
      return;
    }
    if (!_supported) return;
    await _channel.invokeMethod<void>('deleteFor', id);
  }

  Future<String?> _linuxRead(String key) async {
    try {
      final value = await _linuxStorage.read(key: key);
      appLogger.debug(
        'Linux 安全存储读取完成',
        category: DiagnosticLogCategory.security,
        fields: <String, Object?>{'hasValue': value != null},
      );
      return value;
    } on Object catch (error) {
      // Secret Service 未运行（如无桌面钥匙串）时读取失败；调用方按
      // “无已保存 authkey”处理，让用户手动输入，不抛出崩溃。
      appLogger.warning(
        'Linux 安全存储读取失败',
        category: DiagnosticLogCategory.security,
        fields: <String, Object?>{
          'errorType': error.runtimeType.toString(),
          'exception': error.toString(),
        },
      );
      return null;
    }
  }

  Future<void> _linuxWrite(String key, String value) async {
    try {
      await _linuxStorage.write(key: key, value: value);
      appLogger.info(
        'Linux 安全存储写入完成',
        category: DiagnosticLogCategory.security,
      );
    } on Object catch (error, stackTrace) {
      appLogger.error(
        'Linux 安全存储写入失败：$error',
        category: DiagnosticLogCategory.security,
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _linuxDelete(String key) async {
    try {
      await _linuxStorage.delete(key: key);
      appLogger.info(
        'Linux 安全存储删除完成',
        category: DiagnosticLogCategory.security,
      );
    } on Object catch (error, stackTrace) {
      appLogger.error(
        'Linux 安全存储删除失败：$error',
        category: DiagnosticLogCategory.security,
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  bool get _isLinux => defaultTargetPlatform == TargetPlatform.linux;

  bool get _supported => switch (defaultTargetPlatform) {
        TargetPlatform.windows ||
        TargetPlatform.android ||
        TargetPlatform.macOS =>
          true,
        _ => false,
      };
}
