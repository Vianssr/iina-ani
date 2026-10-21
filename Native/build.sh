#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$ROOT/Native"
LOCK="$NATIVE/deps.lock"
WORK="$ROOT/.build/torrent"

if [[ $# -ne 1 || ( "$1" != arm64 && "$1" != x86_64 ) ]]; then
    echo "usage: bash Native/build.sh {arm64|x86_64}" >&2
    exit 2
fi
ARCH="$1"

# shellcheck disable=SC1090
source "$LOCK"
DOWNLOADS="$WORK/downloads"
mkdir -p "$DOWNLOADS" "$WORK/tools" "$WORK/src"

# Hold a kernel lock through the inherited descriptor. Process exit releases it,
# including interrupted builds; a stale directory must never block future builds.
exec 9>"$WORK/build.lockfile"
/usr/bin/lockf 9

fetch_locked() {
    local name="$1" url="$2" expected="$3"
    local path="$DOWNLOADS/$name"
    if [[ ! -f "$path" ]] || [[ "$(shasum -a 256 "$path" | cut -d ' ' -f 1)" != "$expected" ]]; then
        rm -f "$path"
        curl --fail --location --retry 3 --retry-delay 1 "$url" --output "$path"
    fi
    local actual
    actual="$(shasum -a 256 "$path" | cut -d ' ' -f 1)"
    if [[ "$actual" != "$expected" ]]; then
        echo "SHA-256 mismatch for $name: expected $expected, got $actual" >&2
        exit 1
    fi
}

fetch_locked openssl.tar.gz "$OPENSSL_URL" "$OPENSSL_SHA256"
CA_BUNDLE="$NATIVE/licenses/cacert.pem"
CA_BUNDLE_ACTUAL="$(shasum -a 256 "$CA_BUNDLE" | cut -d ' ' -f 1)"
if [[ "$CA_BUNDLE_ACTUAL" != "$CA_BUNDLE_SHA256" ]]; then
    echo "SHA-256 mismatch for bundled CA bundle: expected $CA_BUNDLE_SHA256, got $CA_BUNDLE_ACTUAL" >&2
    exit 1
fi
fetch_locked libtorrent.tar.gz "$LIBTORRENT_URL" "$LIBTORRENT_SHA256"
fetch_locked try_signal.tar.gz "$TRY_SIGNAL_URL" "$TRY_SIGNAL_SHA256"
fetch_locked boost_1_89_0.tar.bz2 "$BOOST_URL" "$BOOST_SHA256"
fetch_locked cmake.tar.gz "$CMAKE_URL" "$CMAKE_SHA256"

OPENSSL_SOURCE="$WORK/$ARCH/openssl-src-$OPENSSL_VERSION"
OPENSSL_SOURCE_MARKER="$WORK/$ARCH/.openssl-$OPENSSL_VERSION.sha256"
if [[ ! -f "$OPENSSL_SOURCE_MARKER" ]] || [[ "$(cat "$OPENSSL_SOURCE_MARKER")" != "$OPENSSL_SHA256" ]] || [[ ! -f "$OPENSSL_SOURCE/LICENSE.txt" ]]; then
    rm -rf "$OPENSSL_SOURCE"
    mkdir -p "$OPENSSL_SOURCE"
    tar -xzf "$DOWNLOADS/openssl.tar.gz" -C "$OPENSSL_SOURCE" --strip-components=1
    printf '%s' "$OPENSSL_SHA256" > "$OPENSSL_SOURCE_MARKER"
fi

OPENSSL_INSTALL="$WORK/$ARCH/openssl-install"
if [[ ! -f "$OPENSSL_INSTALL/lib/libssl.a" ]] || [[ ! -f "$OPENSSL_INSTALL/lib/libcrypto.a" ]] || [[ ! -f "$OPENSSL_INSTALL/include/openssl/ssl.h" ]] || [[ ! -f "$OPENSSL_INSTALL/.source.sha256" ]] || [[ "$(cat "$OPENSSL_INSTALL/.source.sha256")" != "$OPENSSL_SHA256:$ARCH" ]]; then
    rm -rf "$OPENSSL_INSTALL"
    mkdir -p "$OPENSSL_INSTALL"
    case "$ARCH" in
        arm64) OPENSSL_TARGET=darwin64-arm64-cc ;;
        x86_64) OPENSSL_TARGET=darwin64-x86_64-cc ;;
    esac
    (
        cd "$OPENSSL_SOURCE"
        SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" CC="$(xcrun --find clang)" CFLAGS="-arch $ARCH -isysroot $(xcrun --sdk macosx --show-sdk-path) -mmacosx-version-min=13.5" ./Configure "$OPENSSL_TARGET" no-shared no-tests no-apps no-module --prefix="$OPENSSL_INSTALL" --openssldir="$OPENSSL_INSTALL/ssl"
        make -C "$OPENSSL_SOURCE" -j"$(sysctl -n hw.logicalcpu)"
        make -C "$OPENSSL_SOURCE" install_sw
    )
    printf '%s' "$OPENSSL_SHA256:$ARCH" > "$OPENSSL_INSTALL/.source.sha256"
fi

SOURCE="$WORK/src/libtorrent"
BOOST="$WORK/src/boost_1_89_0"
SOURCE_MARKER="$WORK/src/.inputs.sha256"
INPUT_MARKER="$LIBTORRENT_SHA256:$TRY_SIGNAL_SHA256:$BOOST_SHA256:$CMAKE_SHA256"
if [[ ! -f "$SOURCE_MARKER" ]] || [[ "$(cat "$SOURCE_MARKER")" != "$INPUT_MARKER" ]] || [[ ! -f "$SOURCE/CMakeLists.txt" ]] || [[ ! -f "$BOOST/boost/version.hpp" ]] || [[ ! -f "$SOURCE/deps/try_signal/try_signal.cpp" ]]; then
    rm -rf "$SOURCE" "$BOOST"
    mkdir -p "$SOURCE/deps/try_signal"
    tar -xzf "$DOWNLOADS/libtorrent.tar.gz" -C "$SOURCE" --strip-components=1
    tar -xzf "$DOWNLOADS/try_signal.tar.gz" -C "$SOURCE/deps/try_signal" --strip-components=1
    tar -xjf "$DOWNLOADS/boost_1_89_0.tar.bz2" -C "$WORK/src"
    printf '%s' "$INPUT_MARKER" > "$SOURCE_MARKER"
fi

TOOLS="$WORK/tools/cmake"
TOOL_MARKER="$WORK/tools/.cmake.sha256"
if [[ ! -f "$TOOL_MARKER" ]] || [[ "$(cat "$TOOL_MARKER")" != "$CMAKE_SHA256" ]]; then
    rm -rf "$TOOLS"
    mkdir -p "$TOOLS"
    tar -xzf "$DOWNLOADS/cmake.tar.gz" -C "$TOOLS" --strip-components=1
    printf '%s' "$CMAKE_SHA256" > "$TOOL_MARKER"
fi
CMAKE="$TOOLS/CMake.app/Contents/bin/cmake"
if [[ ! -x "$CMAKE" ]]; then CMAKE="$TOOLS/bin/cmake"; fi
BUILD="$WORK/$ARCH/build"
INSTALL="$WORK/$ARCH/install"
mkdir -p "$BUILD" "$INSTALL/lib"
cp "$OPENSSL_INSTALL/lib/libssl.a" "$OPENSSL_INSTALL/lib/libcrypto.a" "$INSTALL/lib/"

"$CMAKE" -S "$NATIVE" -B "$BUILD" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.5 \
    -DCMAKE_C_COMPILER="$(xcrun --find clang)" \
    -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
    -DLIBTORRENT_SOURCE_DIR="$SOURCE" \
    -DBOOST_ROOT="$BOOST" \
    -DBoost_ROOT="$BOOST" \
    -DBoost_NO_BOOST_CMAKE=ON \
    -DBoost_NO_SYSTEM_PATHS=ON \
    -DOPENSSL_ROOT_DIR="$OPENSSL_INSTALL" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DCMAKE_PREFIX_PATH="$OPENSSL_INSTALL" \
    -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=FALSE \
    -DCMAKE_DISABLE_FIND_PACKAGE_GnuTLS=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_LibGcrypt=TRUE
"$CMAKE" --build "$BUILD" --parallel "$(sysctl -n hw.logicalcpu)"
"$CMAKE" --install "$BUILD"

# Boost is header-only in libtorrent 2.1.2; include the exact locked headers so
# downstream C++ compilation does not depend on a machine-installed Boost.
mkdir -p "$INSTALL/include/boost"
ditto "$BOOST/boost" "$INSTALL/include/boost"
