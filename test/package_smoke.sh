#!/bin/sh
# Build the actual Hex tarball and compile a consumer against only its contents.
# No publish and no network dependency fetch. Run from any directory.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/bendler-package.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM
cd "$root"
mix hex.build --output "$tmp/bendler.tar"
mkdir "$tmp/package"
tar -xf "$tmp/bendler.tar" -C "$tmp/package" contents.tar.gz
tar -xzf "$tmp/package/contents.tar.gz" -C "$tmp/package"
test -f "$tmp/package/priv/c/bendler_launcher.c"
test -f "$tmp/package/priv/bend/bendler.bend"
test ! -d "$tmp/package/_build"
test ! -d "$tmp/package/test"
test ! -d "$tmp/package/deps"
BENDLER_PACKAGE_SOURCE="$tmp/package" sh "$root/test/release_smoke.sh"
echo 'Hex package: fresh consumer, clean/rebuild and compiler-free release passed'
