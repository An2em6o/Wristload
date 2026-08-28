#!/usr/bin/env bash
# Build-only script: regenerate page registry + pub get + `flutter build linux`.
# No analyze, no tests, no packaging, no auto-launch.
#
# 用法:
#   tool/build_linux.sh            # debug
#   tool/build_linux.sh release    # 发布构建
#
# 中国大陆网络环境（pub.dev 直连/代理不可达时）请先设置镜像：
#   export PUB_HOSTED_URL=https://pub.flutter-io.cn
#   export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
#
# 构建依赖（Ubuntu/Debian）:
#   sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev \
#     liblzma-dev libayatana-appindicator3-dev libsecret-1-dev
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter="$(command -v flutter || true)"
if [ -z "$flutter" ] && [ -n "${FLUTTER_ROOT:-}" ] && [ -x "${FLUTTER_ROOT}/bin/flutter" ]; then
  flutter="${FLUTTER_ROOT}/bin/flutter"
fi
if [ -z "$flutter" ]; then
  echo "错误：未找到 flutter。请将其加入 PATH，或设置 FLUTTER_ROOT。" >&2
  exit 1
fi

mode="${1:-debug}"
case "$mode" in
  debug|profile|release) ;;
  *)
    echo "用法: $0 [debug|profile|release]（默认 debug）" >&2
    exit 1
    ;;
esac

cd "$project_root"
echo "== 页面注册表生成 =="
dart run tool/generate_page_registry.dart

echo "== 依赖 =="
"$flutter" pub get

echo "== Linux ${mode} 构建（不运行测试） =="
"$flutter" build linux --"$mode"

# 产物目录按构建机架构定位（x86_64 -> x64，aarch64 -> arm64）。
case "$(uname -m)" in
  x86_64) arch="x64" ;;
  aarch64) arch="arm64" ;;
  *) arch="$(uname -m)" ;;
esac
bundle="${project_root}/build/linux/${arch}/${mode}/bundle"
if [ -d "$bundle" ]; then
  echo ""
  echo "构建产物: ${bundle}/wristload"
else
  echo ""
  echo "构建完成；产物目录为 build/linux/${arch}/${mode}/ 下对应目录。"
fi
