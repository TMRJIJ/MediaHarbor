#!/bin/sh
# Build the bundled LGPL FFmpeg CLI from the corresponding source archive.
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
destination=$(dirname "$source_dir")/ffmpeg
work=$(mktemp -d /tmp/mediaharbor-ffmpeg-build.XXXXXX)
trap 'rm -rf "$work"' EXIT
archive="$source_dir/ffmpeg-9.0.2.tar.xz"
expected=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
actual=$(shasum -a 256 "$archive" | awk '{print $1}')
if [ "$actual" != "$expected" ]; then
    echo "FFmpeg source archive checksum mismatch." >&2
    exit 1
fi
tar -xJf "$archive" -C "$work"
source="$work/ffmpeg-9.0.2"
(cd "$source" && patch -p1 < "$source_dir/scoped-cookies.patch")

sdk=$(xcrun --sdk macosx --show-sdk-path)
export MEDIAHARBOR_MACOS_SDK="$sdk"
cat > "$work/sdk-pkg-config" <<'PKGCONFIG'
#!/bin/sh
case "$1" in
  --version) echo 1.0 ;;
  --exists) test -f "$MEDIAHARBOR_MACOS_SDK/usr/lib/libxml2.tbd" ;;
  --cflags) printf '%s\n' "-I$MEDIAHARBOR_MACOS_SDK/usr/include/libxml2" ;;
  --libs) echo -lxml2 ;;
  --variable=includedir) printf '%s\n' "$MEDIAHARBOR_MACOS_SDK/usr/include/libxml2" ;;
  *) exit 1 ;;
esac
PKGCONFIG
chmod +x "$work/sdk-pkg-config"

build() {
    slice=$1
    mkdir "$work/$slice"
    cd "$work/$slice"
    "$source/configure" \
        --cc="$(xcrun --find clang)" --arch="$slice" --target-os=darwin \
        --enable-cross-compile --sysroot="$sdk" \
        --extra-cflags="-arch $slice -mmacosx-version-min=26.0" \
        --extra-ldflags="-arch $slice -mmacosx-version-min=26.0" \
        --pkg-config="$work/sdk-pkg-config" \
        --disable-shared --enable-static --disable-doc --disable-debug \
        --disable-autodetect --disable-everything --disable-asm \
        --disable-ffplay --disable-ffprobe --disable-avdevice \
        --enable-network --enable-securetransport --enable-libxml2 \
        --enable-protocol=file,http,https,tcp,tls,crypto,pipe \
        --enable-demuxer=hls,dash,mpegts,mov,matroska,aac,mp3,webvtt \
        --enable-muxer=mp4,matroska \
        --enable-decoder=aac,aac_latm,ac3,eac3,mp3,h264,hevc,av1,vp9,opus,mpeg2video,mpeg4 \
        --enable-parser=aac,ac3,av1,h264,hevc,mpeg4video,mpegaudio,opus,vp9 \
        --enable-bsf=aac_adtstoasc,extract_extradata,hevc_mp4toannexb,h264_mp4toannexb
    make -j "${MEDIAHARBOR_BUILD_JOBS:-6}" ffmpeg
    touch "$work/$slice/complete"
}
build arm64 > "$work/arm64.log" 2>&1 &
build x86_64 > "$work/x86_64.log" 2>&1 &
wait
result=0
for slice in arm64 x86_64; do
    if [ ! -f "$work/$slice/complete" ]; then
        tail -80 "$work/$slice.log"
        result=1
    fi
done
test "$result" -eq 0
lipo -create "$work/arm64/ffmpeg" "$work/x86_64/ffmpeg" -output "$destination"
codesign --force --sign - "$destination"
lipo -archs "$destination"
