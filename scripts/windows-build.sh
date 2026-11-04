#!/usr/bin/env bash
# 在 GitHub 的 Windows 机器上（MSYS2 / MINGW64 环境）运行。
# 产出两套：
#   out/win-x64/full/bin/ffmpeg.exe、ffprobe.exe   完整版单文件（含 x264、x265，GPL，静态链接，不依赖别的 dll）
#   out/win-x64/lgpl/bin/av*.dll、sw*.dll + 依赖 dll   LGPL 版动态库（不含 x264、x265），给软件里直接调用
set -u -o pipefail

FFVER="${FFMPEG_VERSION:-8.1.3}"
ROOT="$PWD/build/win-x64"
OUT="$PWD/out/win-x64"
J="$(nproc)"
mkdir -p "$ROOT" "$OUT/full/bin" "$OUT/lgpl/bin" "$OUT/logs"
REPORT="$OUT/dep-report.txt"
: > "$REPORT"

git clone --depth 1 --branch "n$FFVER" https://github.com/FFmpeg/FFmpeg.git "$ROOT/ffmpeg" \
  || { echo "下载 FFmpeg n$FFVER 失败（版本号对不对？）"; exit 1; }

# 两套都能用的库：清单和安卓共用 scripts/libflags.sh，保证功能一致
LIBDIR=/mingw64/lib; USE_MBEDTLS=0
# shellcheck source=libflags.sh
source "$(dirname "$0")/libflags.sh"

# Windows 专有的硬件加速（对界面来说和安卓的 MediaCodec 是同一个"硬件"开关）
HW=(--enable-d3d11va --enable-dxva2 --enable-mediafoundation --enable-schannel)
have ffnvcodec && HW+=(--enable-cuda --enable-cuvid --enable-nvenc --enable-nvdec --enable-ffnvcodec)
have vpl && HW+=(--enable-libvpl)
[ -f /mingw64/include/AMF/core/Factory.h ] && HW+=(--enable-amf)

COMMON=(--arch=x86_64 --target-os=mingw32 --disable-autodetect --disable-doc --disable-debug --disable-avdevice
        --enable-zlib --enable-bzlib --enable-lzma --enable-iconv --pkg-config-flags=--static)

ff_conf() { # 名字 额外参数...
  local name="$1"; shift
  rm -rf "$ROOT/ffb-$name"; mkdir -p "$ROOT/ffb-$name"; cd "$ROOT/ffb-$name" || return 1
  "$ROOT/ffmpeg/configure" --prefix="$ROOT/ffi-$name" "${COMMON[@]}" "${LIBFLAGS[@]}" "${HW[@]}" "$@" 2>&1 \
    | tee "$OUT/logs/configure-$name.txt"
  local rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || cp ffbuild/config.log "$OUT/logs/config-$name.log" 2>/dev/null
  return "$rc"
}

# ---- 完整版：单个 exe，全部静态链接 ----
FULL=(--enable-gpl --enable-programs --disable-shared --enable-static --extra-ldflags=-static)
have x264 && FULL+=(--enable-libx264)
have x265 && FULL+=(--enable-libx265)
if ff_conf full "${FULL[@]}" && make -C "$ROOT/ffb-full" -j"$J" && make -C "$ROOT/ffb-full" install; then
  cp "$ROOT/ffi-full/bin/ffmpeg.exe" "$ROOT/ffi-full/bin/ffprobe.exe" "$OUT/full/bin/"
  strip --strip-unneeded "$OUT/full/bin/"*.exe
  echo "OK    ffmpeg完整版（exe）" | tee -a "$REPORT"
else
  echo "FAIL  ffmpeg完整版（exe）" | tee -a "$REPORT"
fi

# ---- LGPL 版：动态库 + 它们依赖的 dll ----
if ff_conf lgpl --disable-gpl --disable-nonfree --enable-shared --disable-static --disable-programs \
   && make -C "$ROOT/ffb-lgpl" -j"$J" && make -C "$ROOT/ffb-lgpl" install; then
  cp "$ROOT"/ffi-lgpl/bin/*.dll "$OUT/lgpl/bin/"
  for d in "$OUT"/lgpl/bin/av*.dll "$OUT"/lgpl/bin/sw*.dll; do
    ldd "$d" | awk '/\/mingw64\/bin\//{print $3}'
  done | sort -u | while read -r f; do cp -n "$f" "$OUT/lgpl/bin/"; done
  strip --strip-unneeded "$OUT"/lgpl/bin/*.dll 2>/dev/null || true
  echo "OK    ffmpeg LGPL 动态库" | tee -a "$REPORT"
else
  echo "FAIL  ffmpeg LGPL 动态库" | tee -a "$REPORT"
fi

for n in full lgpl; do
  { echo; echo "--- $n 启用的外部库 ---"; sed -n '/^External libraries:/,/^$/p' "$OUT/logs/configure-$n.txt" 2>/dev/null; } >> "$REPORT"
done
cat "$REPORT"
