import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 连接过的设备历史记录。与 authkey 绑定解耦：没有保存 authkey 的设备
/// 同样会被记住，UI 可从 AuthKeyBindingStore 查询该设备是否有可用 key。
class KnownDeviceRecord {
  const KnownDeviceRecord({
    required this.id,
    required this.name,
    this.address,
    required this.lastConnectedAt,
  });

  /// 设备 UUID（如 00000000-0000-0000-0000-0816d5945466）。
  final String id;

  /// 广播名称（如 Xiaomi Smart Band 9 5466）。
  final String name;

  /// 经典蓝牙 MAC 地址（Linux/Windows 直连 resolve 用，可空）。
  final String? address;

  final DateTime lastConnectedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        if (address != null) 'address': address,
        'lastConnectedAt': lastConnectedAt.toIso8601String(),
      };

  static KnownDeviceRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    final address = value['address'];
    final lastConnectedAt =
        DateTime.tryParse(value['lastConnectedAt']?.toString() ?? '');
    if (id is! String || name is! String || lastConnectedAt == null) {
      return null;
    }
    return KnownDeviceRecord(
      id: id,
      name: name,
      address: address is String ? address : null,
      lastConnectedAt: lastConnectedAt,
    );
  }
}

/// 持久化连接过的设备列表（最近连接在前）。
class KnownDevicesStore {
  static const _preferenceKey = 'known_devices';

  Future<List<KnownDeviceRecord>> readAll() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_preferenceKey);
    final devices = <KnownDeviceRecord>[];
    if (encoded != null) {
      try {
        final values = jsonDecode(encoded);
        if (values is List) {
          for (final value in values) {
            final record = KnownDeviceRecord.fromJson(value);
            if (record != null) devices.add(record);
          }
        }
      } on Object {
        // 忽略损坏元数据，让用户重新建立记录。
      }
    }
    devices.sort((a, b) => b.lastConnectedAt.compareTo(a.lastConnectedAt));
    return devices;
  }

  /// 新增或更新某设备的连接记录（按 id 匹配，大小写不敏感）。
  Future<void> upsert({
    required String id,
    required String name,
    String? address,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final devices = await readAll();
    final normalizedId = id.trim();
    devices.removeWhere(
      (d) => d.id.toLowerCase() == normalizedId.toLowerCase(),
    );
    devices.insert(
      0,
      KnownDeviceRecord(
        id: normalizedId,
        name: name.trim().isEmpty ? '已保存设备' : name.trim(),
        address: address?.trim(),
        lastConnectedAt: DateTime.now(),
      ),
    );
    await preferences.setString(
      _preferenceKey,
      jsonEncode(devices.map((d) => d.toJson()).toList()),
    );
  }

  Future<void> remove(String id) async {
    final preferences = await SharedPreferences.getInstance();
    final devices = await readAll();
    devices.removeWhere(
      (d) => d.id.toLowerCase() == id.trim().toLowerCase(),
    );
    await preferences.setString(
      _preferenceKey,
      jsonEncode(devices.map((d) => d.toJson()).toList()),
    );
  }
}
