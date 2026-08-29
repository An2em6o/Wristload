# 更新日志

## [0.1.0] - 2026-08-29

### 修复
- 修复 Linux 上手环固件版本无法获取的问题：恢复 SPP 版本查询（App SppVersionReader 同款 BA-DC-FE 帧，2 秒超时兜底、不影响 V2 鉴权流程），并修复 type=106 版本回包解析（优先按可打印 ASCII 解码，回退数值连接，不再显示 hex 乱码）
- 修复手表连接失败后无法再次搜索的问题：失败路径统一复位扫描标志 `_isScanning` 与原生扫描，避免残留导致 `beginScan` 首行拦截
- 修复 Linux 扫描启动偶发 `org.bluez.Error.InProgress: Operation already in progress` 报错：BlueZ 已在进行 discovery 时按幂等成功处理

### 新增
- Linux 平台支持：经典蓝牙 RFCOMM/SPP 连接（`wristload_rfcomm_linux` 插件）、免扫描直连、快应用安装
- GitHub Actions 工作流：x86-64 构建 + deb 打包 + 自动发布 Release
- deb 打包脚本 `tool/build_deb.sh`（arm64 / amd64）

### 其他
- 版本号定为 0.1.0
