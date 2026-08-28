#!/usr/bin/env bash
# 将 Flutter Linux release 产物打包为 .deb（dpkg-deb，零额外依赖）。
#
# 用法:
#   tool/build_linux.sh release   # 先生成 release 产物
#   tool/build_deb.sh             # 再打包为 deb
#
# 产物: dist/wristload_<version>_<arch>.deb
# 安装: sudo dpkg -i dist/wristload_*.deb
# 卸载: sudo dpkg -r wristload
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

# 架构（构建机架构决定 deb 架构与 bundle 子目录）
case "$(uname -m)" in
  x86_64) arch="amd64"; bundle_arch="x64" ;;
  aarch64) arch="arm64"; bundle_arch="arm64" ;;
  *) echo "错误：不支持的架构 $(uname -m)" >&2; exit 1 ;;
esac

bundle="${project_root}/build/linux/${bundle_arch}/release/bundle"
if [ ! -d "$bundle" ]; then
  echo "错误：未找到 release 产物 ${bundle}" >&2
  echo "请先运行: tool/build_linux.sh release" >&2
  exit 1
fi

version="$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"
[ -n "$version" ] || version="0.1.0"

pkg="wristload_${version}_${arch}"
root="${TMPDIR:-/tmp}/${pkg}"
rm -rf "$root"
mkdir -p \
  "$root/DEBIAN" \
  "$root/opt/wristload" \
  "$root/usr/bin" \
  "$root/usr/share/applications" \
  "$root/usr/share/icons/hicolor/256x256/apps"

# ---- DEBIAN/control ----
cat > "$root/DEBIAN/control" <<EOF
Package: wristload
Version: $version
Section: utils
Priority: optional
Architecture: $arch
Maintainer: pengchegnkai <noreply@github.com>
Installed-Size: $(du -sk "$bundle" | awk '{print $1}')
Depends: libgtk-3-0 (>= 3.22), libayatana-appindicator3-1, libsecret-1-0, liblzma5
Description: Wristload - 小米手环桌面客户端
 跨平台小米手环（Mi Band / 手环 9 等）经典蓝牙客户端。
 支持连接、鉴权、快应用安装与表盘管理。
Homepage: https://github.com/pengchegnkai/Wristload-Next
EOF

# ---- /opt/wristload（应用本体：二进制 + data + lib）----
cp -a "$bundle/." "$root/opt/wristload/"

# ---- /usr/bin/wristload（启动包装）----
cat > "$root/usr/bin/wristload" <<'EOF'
#!/usr/bin/env bash
exec /opt/wristload/wristload "$@"
EOF
chmod +x "$root/usr/bin/wristload"

# ---- .desktop ----
cat > "$root/usr/share/applications/com.anemo.wristload.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Wristload
GenericName=Mi Band Client
Comment=小米手环桌面客户端
Exec=/usr/bin/wristload
Icon=com.anemo.wristload
Terminal=false
Categories=Utility;
StartupWMClass=com.anemo.wristload
EOF

# ---- 图标（复用 macos AppIcon 的 256px PNG）----
icon_src="${project_root}/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png"
if [ -f "$icon_src" ]; then
  cp "$icon_src" "$root/usr/share/icons/hicolor/256x256/apps/com.anemo.wristload.png"
fi

# ---- 打包 ----
mkdir -p "${project_root}/dist"
dpkg-deb --build --root-owner-group "$root" "${project_root}/dist/${pkg}.deb"
echo ""
echo "已生成: dist/${pkg}.deb"
echo "安装:   sudo dpkg -i dist/${pkg}.deb"
echo "卸载:   sudo dpkg -r wristload"
