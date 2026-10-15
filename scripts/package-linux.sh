#!/usr/bin/env bash
# 把 Linux 的 Flutter bundle 打包成可以發佈的格式(release workflow 用,本機也能跑)。
#
#   scripts/package-linux.sh <版本,例如 1.0.0>
#
# 前置:core 已 `cargo build --release -p tterm-ffi`,app 已 `flutter build linux --release`
# (CMake 的 install 規則會把 libtterm_ffi.so 放進 bundle/lib)。
#
# 產出到 dist/:
#   tterminal-<版本>-linux-<arch>.tar.gz   解開就能跑的資料夾
#   tterminal_<版本>_<deb arch>.deb         Debian / Ubuntu
#   tterminal-<版本>-1.<rpm arch>.rpm       Fedora / openSUSE / RHEL 系
#   tterminal-<版本>-<arch>.AppImage        單檔,大多數發行版都能直接跑
#
# 安裝後的位置:/opt/tterminal/(整個 bundle),/usr/bin/tterminal 是指過去的連結。
set -euo pipefail

version=${1:?版本號,例如 1.0.0}
# deb / rpm 的版本欄位不能有 -(rpm 直接拒絕,deb 會當成修訂號);預發佈版慣例用 ~,
# 例如 0.0.0-f67273f → 0.0.0~f67273f,排序也會排在正式版 0.0.0 之前。檔名維持原樣。
pkg_version=${version//-/\~}
repo=$(cd "$(dirname "$0")/.." && pwd)
dist="$repo/dist"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

case "$(uname -m)" in
    x86_64)  arch=x64;   deb_arch=amd64; rpm_arch=x86_64;  ai_arch=x86_64 ;;
    aarch64) arch=arm64; deb_arch=arm64; rpm_arch=aarch64; ai_arch=aarch64 ;;
    *) echo "不支援的架構:$(uname -m)" >&2; exit 1 ;;
esac

bundle="$repo/app/build/linux/$arch/release/bundle"
[ -x "$bundle/tterminal" ] || { echo "找不到 $bundle/tterminal,先跑 flutter build linux --release" >&2; exit 1; }
[ -f "$bundle/lib/libtterm_ffi.so" ] || { echo "bundle 裡沒有 libtterm_ffi.so" >&2; exit 1; }
mkdir -p "$dist"

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }

# 共用的安裝樹:/opt/tterminal + /usr/bin 連結 + desktop 檔與圖示
stage="$work/stage"
install_tree() {
    local root=$1
    mkdir -p "$root/opt/tterminal" "$root/usr/bin" "$root/usr/share/applications"
    cp -a "$bundle/." "$root/opt/tterminal/"
    ln -sf /opt/tterminal/tterminal "$root/usr/bin/tterminal"
    cp "$repo/packaging/linux/dev.tterm.tterminal.desktop" "$root/usr/share/applications/"
    for size in 128 256 512; do
        mkdir -p "$root/usr/share/icons/hicolor/${size}x${size}/apps"
        cp "$repo/packaging/linux/icons/$size.png" \
            "$root/usr/share/icons/hicolor/${size}x${size}/apps/dev.tterm.tterminal.png"
    done
}
install_tree "$stage"
installed_kb=$(du -sk "$stage" | cut -f1)

step 'tar.gz'
tarball="$dist/tterminal-$version-linux-$arch.tar.gz"
mkdir -p "$work/tar/tterminal-$version"
cp -a "$bundle/." "$work/tar/tterminal-$version/"
tar -C "$work/tar" -czf "$tarball" "tterminal-$version"
echo "  $tarball"

step 'deb'
debroot="$work/deb"
install_tree "$debroot"
mkdir -p "$debroot/DEBIAN"
cat > "$debroot/DEBIAN/control" <<EOF
Package: tterminal
Version: $pkg_version
Architecture: $deb_arch
Maintainer: tterminal <https://github.com/tterminal-app/tterminal>
Installed-Size: $installed_kb
Depends: libgtk-3-0t64 | libgtk-3-0
Section: net
Priority: optional
Homepage: https://github.com/tterminal-app/tterminal
Description: SSH terminal with end-to-end encrypted sync
 GPU-rendered SSH terminal that handles input methods properly, with hosts
 and keys synced through a self-hosted, zero-knowledge server.
EOF
deb="$dist/tterminal_${version}_$deb_arch.deb"
dpkg-deb --root-owner-group --build "$debroot" "$deb" >/dev/null
echo "  $deb"

step 'rpm'
if command -v rpmbuild >/dev/null 2>&1; then
    rpmtop="$work/rpm"
    mkdir -p "$rpmtop"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
    cat > "$rpmtop/SPECS/tterminal.spec" <<EOF
# 預編譯的 bundle:不要 strip(Flutter 的 libapp.so 是 AOT 快照,strip 會壞),也不要 debuginfo
%global debug_package %{nil}
%global __os_install_post %{nil}

Name:           tterminal
Version:        $pkg_version
Release:        1
Summary:        SSH terminal with end-to-end encrypted sync
License:        GPL-3.0-only
URL:            https://github.com/tterminal-app/tterminal
Requires:       gtk3
AutoReqProv:    no

%description
GPU-rendered SSH terminal that handles input methods properly, with hosts
and keys synced through a self-hosted, zero-knowledge server.

%install
mkdir -p %{buildroot}
cp -a $stage/. %{buildroot}/

%files
/opt/tterminal
/usr/bin/tterminal
/usr/share/applications/dev.tterm.tterminal.desktop
/usr/share/icons/hicolor/*/apps/dev.tterm.tterminal.png
EOF
    rpmbuild --quiet --define "_topdir $rpmtop" --target "$rpm_arch" -bb "$rpmtop/SPECS/tterminal.spec"
    cp "$rpmtop/RPMS/$rpm_arch/"*.rpm "$dist/"
    echo "  $(ls "$dist"/tterminal-*."$rpm_arch".rpm)"
else
    echo "  略過:沒有 rpmbuild(apt install rpm)"
fi

step 'AppImage'
appdir="$work/tterminal.AppDir"
mkdir -p "$appdir/usr/lib/tterminal"
cp -a "$bundle/." "$appdir/usr/lib/tterminal/"
cp "$repo/packaging/linux/dev.tterm.tterminal.desktop" "$appdir/"
cp "$repo/packaging/linux/icons/256.png" "$appdir/dev.tterm.tterminal.png"
cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
here=$(dirname "$(readlink -f "$0")")
exec "$here/usr/lib/tterminal/tterminal" "$@"
EOF
chmod +x "$appdir/AppRun"
tool="$work/appimagetool"
curl -fsSL -o "$tool" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ai_arch.AppImage"
chmod +x "$tool"
appimage="$dist/tterminal-$version-$ai_arch.AppImage"
# CI 的 runner 沒有 FUSE,用 extract-and-run
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=$ai_arch "$tool" --no-appstream "$appdir" "$appimage" >/dev/null
echo "  $appimage"

step '完成'
ls -lh "$dist"/tterminal*"$version"* "$dist"/tterminal_"$version"* 2>/dev/null
