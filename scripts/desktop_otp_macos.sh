#!/usr/bin/env bash
# Build the Erlang/OTP the macOS desktop installer is packaged with (bb8bc042).
#
#   scripts/desktop_otp_macos.sh <install-dir> [<otp-version>]
#
# desktop_deployment copies every NIF's dylib dependencies into the .app and
# rewrites their load paths with install_name_tool. A stock OTP fails that:
# it links Homebrew's OpenSSL and wxWidgets, and was not linked with header
# room for the longer paths ("larger updated load commands do not fit"). So:
#   - OpenSSL 3 linked statically: no dylib to relocate;
#   - no wx: the window is desktop_webview's native host, and without wx.hrl
#     the `desktop` dependency does not require :wx;
#   - -headerpad_max_install_names for whatever is still relocated.
# Used by the local build and by CI; needs Homebrew's openssl@3.
set -euo pipefail

PREFIX="${1:?usage: $0 <install-dir> [<otp-version>]}"
OTP_VERSION="${2:-28.1}"
WORK="${KERL_BASE_DIR:-$(dirname "$PREFIX")/kerl}"
OPENSSL="$(brew --prefix openssl@3)"

mkdir -p "$WORK"
KERL="$WORK/kerl"
if [[ ! -x "$KERL" ]]; then
  curl -fsSL -o "$KERL" https://raw.githubusercontent.com/kerl/kerl/master/kerl
  chmod +x "$KERL"
fi

export KERL_BASE_DIR="$WORK"
export KERL_BUILD_DOCS=no
export KERL_CONFIGURE_OPTIONS="--without-wx --without-javac --without-odbc --without-debugger --without-observer --without-et --with-ssl=$OPENSSL --disable-dynamic-ssl-lib"
export LDFLAGS="-Wl,-headerpad_max_install_names"

"$KERL" build "$OTP_VERSION" "desktop-$OTP_VERSION"
"$KERL" install "desktop-$OTP_VERSION" "$PREFIX"

test ! -e "$PREFIX"/lib/wx-* || { echo "wx was built; expected --without-wx" >&2; exit 1; }
if otool -L "$PREFIX"/lib/crypto-*/priv/lib/crypto.so | grep -q "libcrypto"; then
  echo "crypto.so links a libcrypto dylib; expected static OpenSSL" >&2
  exit 1
fi
echo "Packaging OTP $OTP_VERSION at $PREFIX"
