#!/usr/bin/env bash
set -u -o pipefail

TARGET="${1:?缺少参数：android-arm64 或 android-x86_64}"
FFVER="${FFMPEG_VERSION:-8.1.3}"
API=24
NDK="${ANDROID_NDK_HOME:?没有找到 ANDROID_NDK_HOME}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
J="$(nproc)"

case "$TARGET" in
  android-arm64)  TRIPLE=aarch64-linux-android; ABI=arm64-v8a; ARCH=aarch64; MFAMILY=aarch64; MCPU=armv8-a; VPXTARGET=arm64-linux-gcc ;;
  android-x86_64) TRIPLE=x86_64-linux-android;  ABI=x86_64;    ARCH=x86_64;  MFAMILY=x86_64;  MCPU=x86_64;  VPXTARGET=x86_64-linux-gcc ;;
  *) echo "不认识的目标：$TARGET"; exit 1 ;;
esac

PLATFORM=android
PLAT_CFLAGS=""
ROOT="$PWD/build/$TARGET"
SRC="$ROOT/src"
PREFIX="$ROOT/prefix"
OUT="$PWD/out/$TARGET"
mkdir -p "$SRC" "$PREFIX/lib/pkgconfig" "$OUT/full/bin" "$OUT/lgpl/lib" "$OUT/logs"
REPORT="$OUT/dep-report.txt"
: > "$REPORT"

export CC="$TOOLCHAIN/bin/${TRIPLE}${API}-clang"
export CXX="$TOOLCHAIN/bin/${TRIPLE}${API}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export NM="$TOOLCHAIN/bin/llvm-nm"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export LD="$CC"
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="-O2 -fPIC"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH

CMAKE_BASE=(
  -G Ninja
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
  -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_FIND_ROOT_PATH="$PREFIX"
  -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)

cat > "$ROOT/meson-cross.txt" <<MESON
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'
[host_machine]
system = 'android'
cpu_family = '$MFAMILY'
cpu = '$MCPU'
endian = 'little'
[built-in options]
c_args = ['-O2', '-fPIC', '-I$PREFIX/include']
cpp_args = ['-O2', '-fPIC', '-I$PREFIX/include']
c_link_args = ['-L$PREFIX/lib']
cpp_link_args = ['-L$PREFIX/lib']
[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$PREFIX/lib/pkgconfig'
MESON

X264_CFG=(--cross-prefix="$TOOLCHAIN/bin/llvm-")
merge_static() {
  local o="$1"; shift
  { echo "CREATE $o"; for f in "$@"; do echo "ADDLIB $f"; done; echo SAVE; echo END; } | "$AR" -M
}
source "$(dirname "$0")/deps.sh"
run_deps

sed -i 's/-lstdc++//g' "$PREFIX"/lib/pkgconfig/*.pc 2>/dev/null || true

LIBDIR="$PREFIX/lib"
source "$(dirname "$0")/libflags.sh"

rm -rf "$SRC/ffmpeg"
git clone --depth 1 --branch "n$FFVER" https://github.com/FFmpeg/FFmpeg.git "$SRC/ffmpeg" || { echo "下载 FFmpeg n$FFVER 失败（版本号对不对？）"; exit 1; }
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

ff_conf() {
  local name="$1"; shift
  rm -rf "$ROOT/ffb-$name"; mkdir -p "$ROOT/ffb-$name"; cd "$ROOT/ffb-$name" || return 1
  "$SRC/ffmpeg/configure" --prefix="$ROOT/ffi-$name" \
    --enable-cross-compile --target-os=android --arch="$ARCH" \
    --cc="$CC" --cxx="$CXX" --ld="$CXX" --ar="$AR" --nm="$NM" --ranlib="$RANLIB" --strip="$STRIP" \
    --pkg-config=pkg-config --pkg-config-flags=--static \
    --enable-pic --disable-autodetect --disable-doc --disable-debug --disable-avdevice --disable-symver \
    --enable-zlib --enable-jni --enable-mediacodec \
    --extra-cflags="-I$PREFIX/include -fPIC" \
    --extra-ldflags="-L$PREFIX/lib -static-libstdc++" \
    "${LIBFLAGS[@]}" "$@" 2>&1 | tee "$OUT/logs/configure-$name.txt"
  local rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || cp ffbuild/config.log "$OUT/logs/config-$name.log" 2>/dev/null
  return "$rc"
}

FULL=(--enable-gpl --enable-programs --disable-shared --enable-static --enable-pie)
have x264 && FULL+=(--enable-libx264)
have x265 && FULL+=(--enable-libx265)
if ff_conf full "${FULL[@]}" && make -C "$ROOT/ffb-full" -j"$J" && make -C "$ROOT/ffb-full" install; then
  cp "$ROOT/ffi-full/bin/ffmpeg" "$ROOT/ffi-full/bin/ffprobe" "$OUT/full/bin/"
  "$STRIP" --strip-unneeded "$OUT/full/bin/"*
  echo "OK    ffmpeg完整版（可执行文件）" | tee -a "$REPORT"
else
  echo "FAIL  ffmpeg完整版（可执行文件）" | tee -a "$REPORT"
fi

if ff_conf lgpl --disable-gpl --disable-nonfree --disable-programs --disable-shared --enable-static \
   && make -C "$ROOT/ffb-lgpl" -j"$J" && make -C "$ROOT/ffb-lgpl" install; then
  FFLIB="$ROOT/ffi-lgpl/lib"
  EXTRA="$(PKG_CONFIG_LIBDIR="$FFLIB/pkgconfig:$PREFIX/lib/pkgconfig" pkg-config --static --libs \
            libavformat libavcodec libavfilter libswscale libswresample libavutil)"
  "$CXX" -shared -o "$OUT/lgpl/lib/libffmpeg.so" -Wl,-soname,libffmpeg.so \
    -static-libstdc++ \
    -Wl,--whole-archive "$FFLIB/libavformat.a" "$FFLIB/libavcodec.a" "$FFLIB/libavfilter.a" \
      "$FFLIB/libswscale.a" "$FFLIB/libswresample.a" "$FFLIB/libavutil.a" -Wl,--no-whole-archive \
    $EXTRA -landroid -llog -lmediandk -lm -lz -ldl \
    && "$STRIP" --strip-unneeded "$OUT/lgpl/lib/libffmpeg.so" \
    && echo "OK    libffmpeg.so（LGPL）" | tee -a "$REPORT" \
    || echo "FAIL  libffmpeg.so 合并链接" | tee -a "$REPORT"
else
  echo "FAIL  ffmpeg LGPL 版配置/编译" | tee -a "$REPORT"
fi

if ff_conf shared --disable-gpl --disable-nonfree --disable-programs --enable-shared --disable-static; then
  sed -i.bak -e 's|^SLIBNAME_WITH_MAJOR=.*|SLIBNAME_WITH_MAJOR=$(SLIBNAME)|' \
             -e 's|^SLIB_INSTALL_NAME=.*|SLIB_INSTALL_NAME=$(SLIBNAME)|' \
             -e 's|^SLIB_INSTALL_LINKS=.*|SLIB_INSTALL_LINKS=|' "$ROOT/ffb-shared/ffbuild/config.mak"
  rm -f "$ROOT/ffb-shared/ffbuild/config.mak.bak"
  if make -C "$ROOT/ffb-shared" -j"$J" && make -C "$ROOT/ffb-shared" install \
     && ls "$ROOT/ffi-shared/lib/libavcodec.so" >/dev/null 2>&1; then
    mkdir -p "$OUT/lgpl-split/$ABI"
    cp "$ROOT"/ffi-shared/lib/lib{avutil,swresample,swscale,avcodec,avformat,avfilter}.so "$OUT/lgpl-split/$ABI/"
    "$STRIP" --strip-unneeded "$OUT/lgpl-split/$ABI/"*.so
    echo "OK    分开的 .so（LGPL）" | tee -a "$REPORT"
  else
    echo "FAIL  分开的 .so 编译/改名" | tee -a "$REPORT"
  fi
else
  echo "FAIL  分开的 .so 配置" | tee -a "$REPORT"
fi

for n in full lgpl shared; do
  { echo; echo "--- $n 启用的外部库 ---"; sed -n '/^External libraries:/,/^$/p' "$OUT/logs/configure-$n.txt" 2>/dev/null; } >> "$REPORT"
done
cat "$REPORT"
