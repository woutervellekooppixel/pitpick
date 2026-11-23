#!/bin/zsh
# Rebuilds lib/arm64/libturbojpeg.a: libjpeg-turbo 3.2.1, static, Apple Silicon, for macOS 14 and later.
# Needs cmake (brew install cmake) and an internet connection once. Pitpick's build.sh uses the result.
set -e
cd "$(dirname "$0")"
V=3.2.1
SUM=c27ad72a68da151177929aa969ae773a2da5ac2af9ce946079314fdac8cece7f
W=$(mktemp -d)
curl -fsSL -o "$W/src.tar.gz" "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$V/libjpeg-turbo-$V.tar.gz"
echo "$SUM  $W/src.tar.gz" | shasum -a 256 -c
mkdir "$W/src" "$W/build" && tar -xzf "$W/src.tar.gz" -C "$W/src" --strip-components 1
cd "$W/build"
cmake ../src -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DENABLE_SHARED=FALSE -DENABLE_STATIC=TRUE -DWITH_TURBOJPEG=TRUE -DREQUIRE_SIMD=TRUE >/dev/null
make -j8 turbojpeg-static >/dev/null
cd - >/dev/null
cp "$W/build/libturbojpeg.a" lib/arm64/
cp "$W/src/src/turbojpeg.h" include/ 2>/dev/null || cp "$W/src/turbojpeg.h" include/
cp "$W/src/LICENSE.md" "$W/src/README.ijg" .
echo "Done: lib/arm64/libturbojpeg.a ($(du -h lib/arm64/libturbojpeg.a | cut -f1))"
