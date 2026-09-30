#!/usr/bin/env bash
# Builds libtdjson.dylib (TDLib's JSON interface) for arm64 macOS from the commit pinned
# in COMMIT, with OpenSSL linked statically so the dylib has no Homebrew runtime dependency.
#
# Idempotent: re-running with everything already built only re-runs the (fast) install
# step and the link check. Delete vendor/tdlib/build to force a rebuild, or
# vendor/tdlib/src to re-clone.
#
# Layout (all git-ignored):
#   vendor/tdlib/src       TDLib checkout at COMMIT
#   vendor/tdlib/build     CMake build tree (Release)
#   vendor/tdlib/lib       libtdjson.dylib (+ static libs cmake installs)
#   vendor/tdlib/include   td/telegram/td_json_client.h and friends
#
# Prints the absolute path of the produced dylib on the last line.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT="$(tr -d '[:space:]' < "$HERE/COMMIT")"
SRC="$HERE/src"
BUILD="$HERE/build"
PREFIX="$HERE"                      # install puts lib/ and include/ next to this script
DYLIB="$PREFIX/lib/libtdjson.dylib"
OPENSSL="${OPENSSL_ROOT_DIR:-/opt/homebrew/opt/openssl@3}"
JOBS="${JOBS:-18}"
REPO="https://github.com/tdlib/td.git"

log() { printf '\n==> %s\n' "$*" >&2; }

for tool in cmake gperf git; do
  command -v "$tool" >/dev/null || { echo "missing $tool (brew install $tool)" >&2; exit 1; }
done
[ -f "$OPENSSL/lib/libssl.a" ] || { echo "no static OpenSSL at $OPENSSL (brew install openssl@3)" >&2; exit 1; }

start=$(date +%s)

# --- 1. Source at the pinned commit --------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
  log "cloning tdlib/td at $COMMIT"
  rm -rf "$SRC"
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin "$REPO"
  git -C "$SRC" fetch -q --depth 1 origin "$COMMIT"
  git -C "$SRC" checkout -q FETCH_HEAD
fi
have="$(git -C "$SRC" rev-parse HEAD)"
if [ "$have" != "$COMMIT" ]; then
  log "src is at $have, switching to $COMMIT"
  git -C "$SRC" fetch -q --depth 1 origin "$COMMIT"
  git -C "$SRC" checkout -q "$COMMIT"
  rm -rf "$BUILD"
fi

# --- 2. Configure -------------------------------------------------------------------
# OPENSSL_USE_STATIC_LIBS makes FindOpenSSL pick libssl.a/libcrypto.a, so nothing in the
# result points at /opt/homebrew. CMAKE_POLICY_VERSION_MINIMUM keeps cmake 4.x happy with
# any sub-project that still declares an old cmake_minimum_required.
if [ ! -f "$BUILD/CMakeCache.txt" ]; then
  log "configuring (Release, arm64, static OpenSSL from $OPENSSL)"
  cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DOPENSSL_ROOT_DIR="$OPENSSL" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DOPENSSL_SSL_LIBRARY="$OPENSSL/lib/libssl.a" \
    -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL/lib/libcrypto.a" \
    -DOPENSSL_INCLUDE_DIR="$OPENSSL/include" \
    -DZLIB_USE_STATIC_LIBS=OFF \
    -DTD_ENABLE_LTO=OFF \
    -DTD_INSTALL_STATIC_LIBRARIES=OFF \
    -DTD_INSTALL_SHARED_LIBRARIES=ON
fi

# --- 3. Build + install only the JSON client library -----------------------------------
log "building tdjson with -j$JOBS"
cmake --build "$BUILD" --target tdjson -j "$JOBS"

log "installing to $PREFIX/{lib,include}"
# Install the whole tree: it copies headers and the dylib. Static archives are skipped
# because TD_INSTALL_STATIC_LIBRARIES=OFF.
cmake --install "$BUILD" >/dev/null

# --- 4. Verify no Homebrew runtime dependency ------------------------------------------
[ -f "$DYLIB" ] || { echo "expected $DYLIB after install" >&2; exit 1; }
log "checking dynamic dependencies"
otool -L "$DYLIB" >&2
if otool -L "$DYLIB" | grep -q '/opt/homebrew'; then
  echo "libtdjson.dylib still links against /opt/homebrew — OpenSSL was not linked statically" >&2
  exit 1
fi

# The install name is what the Swift package's rpath-free link expects: an absolute path,
# so binaries find the dylib without DYLD_LIBRARY_PATH. Rewriting it invalidates the ad-hoc
# signature, and arm64 macOS refuses to load an unsigned dylib, so re-sign afterwards.
if [ "$(otool -D "$DYLIB" | tail -1)" != "$DYLIB" ]; then
  install_name_tool -id "$DYLIB" "$DYLIB"
  codesign --force --sign - "$DYLIB"
fi

end=$(date +%s)
elapsed=$((end - start))
printf 'build time: %02d:%02d\n' $((elapsed / 60)) $((elapsed % 60)) >&2
echo "$DYLIB"
