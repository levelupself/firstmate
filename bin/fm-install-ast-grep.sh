#!/usr/bin/env bash
# fm-install-ast-grep.sh - install the pinned, verified ast-grep binary.
#
# Usage:
#   fm-install-ast-grep.sh <destination-directory>
#
# Installs only the binary named ast-grep. The upstream archive also contains
# an sg alias, but that name collides with the standard login(1) utility and is
# deliberately never extracted or installed here.
set -eu

FM_AST_GREP_VERSION=0.45.0
FM_AST_GREP_MAX_BYTES=15000000
FM_AST_GREP_REPO=ast-grep/ast-grep

die() {
  printf 'fm-install-ast-grep.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-ast-grep.sh <destination-directory>}
os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ASSET=app-x86_64-unknown-linux-gnu.zip
    SHA256=78931ae35ebac33d9a72b3aecea3e3d62d6e5b0b718ac8bbedfbe69d68421e41
    ;;
  Linux-aarch64|Linux-arm64)
    ASSET=app-aarch64-unknown-linux-gnu.zip
    SHA256=62b60892dafacfa76d6de87157659f880bbf85ff38bdab52db12f1f14ec60f94
    ;;
  Darwin-arm64)
    ASSET=app-aarch64-apple-darwin.zip
    SHA256=ec2e3680f4f84c68b48420bcca01d21389787c7318b52083dde6f46ac12ad946
    ;;
  Darwin-x86_64)
    ASSET=app-x86_64-apple-darwin.zip
    SHA256=78d0d9db2f4dfd964fd313e70e92571c6d4204243ad8f3d0abbb2ffc56e45fc6
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official ast-grep assets are linux/macos x86_64 and aarch64"
    ;;
esac

URL="https://github.com/${FM_AST_GREP_REPO}/releases/download/${FM_AST_GREP_VERSION}/${ASSET}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-ast-grep.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'fm-install-ast-grep.sh: downloading %s from %s\n' "$ASSET" "$URL" >&2
curl -fsSL --max-filesize "$FM_AST_GREP_MAX_BYTES" "$URL" -o "$TMP/$ASSET" \
  || die "download failed for $URL (bounded at $FM_AST_GREP_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the ast-grep asset"
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] \
  || die "checksum mismatch for $ASSET (expected $SHA256, got $ACTUAL_SHA256)"

if command -v python3 >/dev/null 2>&1; then
  python3 - "$TMP/$ASSET" "$TMP/ast-grep" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    with archive.open("ast-grep") as source, open(sys.argv[2], "wb") as destination:
        destination.write(source.read())
PY
elif command -v unzip >/dev/null 2>&1; then
  unzip -p "$TMP/$ASSET" ast-grep > "$TMP/ast-grep"
else
  die "need python3 or unzip to extract the ast-grep release asset"
fi

chmod 0755 "$TMP/ast-grep"
installed_version=$("$TMP/ast-grep" --version 2>/dev/null | awk '{print $2; exit}')
[ "$installed_version" = "$FM_AST_GREP_VERSION" ] \
  || die "installed ast-grep version is '${installed_version:-<empty>}', expected exact pin $FM_AST_GREP_VERSION"

mkdir -p "$DESTINATION"
staged_binary=$(mktemp "$DESTINATION/.ast-grep.XXXXXX")
install -m 0755 "$TMP/ast-grep" "$staged_binary"
mv -f "$staged_binary" "$DESTINATION/ast-grep"

printf 'fm-install-ast-grep.sh: installed ast-grep %s to %s\n' \
  "$installed_version" "$DESTINATION/ast-grep" >&2
"$DESTINATION/ast-grep" --version
