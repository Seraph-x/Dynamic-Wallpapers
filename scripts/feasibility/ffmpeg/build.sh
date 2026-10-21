#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../../.." && pwd)"
dependency_root="$project_root/.build/dependencies/ffmpeg"
archive="${1:?Usage: build.sh SOURCE_ARCHIVE EXPECTED_SHA256 STAGING_ROOT}"
expected_sha="${2:?Expected SHA256 is required}"
build_root="${3:?A unique staging root is required}"
case "$build_root" in
    "$dependency_root"/.build-*) ;;
    *) echo "Staging root must be a unique FFmpeg build directory: $build_root" >&2; exit 1 ;;
esac
if [[ ! -d "$build_root" || -n "$(find "$build_root" -mindepth 1 -print -quit)" ]]; then
    echo "Staging root must exist and be empty: $build_root" >&2
    exit 1
fi
actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "Source SHA256 mismatch: $actual_sha" >&2
    exit 1
fi
mkdir -p "$build_root/source" "$build_root/build" "$build_root/logs"
tar -xf "$archive" -C "$build_root/source" --strip-components=1
# FFmpeg's version.sh probes Git before RELEASE; do not inherit this app's parent repository.
export GIT_CEILING_DIRECTORIES="$build_root"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
cd "$build_root/build"
export MACOSX_DEPLOYMENT_TARGET=14.0
"$build_root/source/configure" \
    --prefix="$build_root/install" \
    --cc=/usr/bin/clang --cxx=/usr/bin/clang++ --arch=arm64 --target-os=darwin \
    --sysroot="$sdk_path" \
    --extra-cflags="-mmacosx-version-min=14.0" \
    --extra-ldflags="-mmacosx-version-min=14.0" \
    --disable-autodetect --disable-network --disable-shared --enable-static \
    --disable-doc --disable-ffplay --disable-debug \
    --enable-videotoolbox --enable-audiotoolbox \
    2>&1 | tee "$build_root/logs/configure.log"
make -j8 2>&1 | tee "$build_root/logs/build.log"
make install 2>&1 | tee "$build_root/logs/install.log"
for tool in ffmpeg ffprobe; do
    binary="$build_root/install/bin/$tool"
    file "$binary"
    otool -L "$binary"
    xcrun vtool -show-build "$binary"
    shasum -a 256 "$binary"
done | tee "$build_root/logs/binary-audit.log"
