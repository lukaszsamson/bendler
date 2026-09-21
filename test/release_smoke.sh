#!/bin/sh
# Uses checked-in consumer fixtures and local telemetry only; no network fetch.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/bendler-release.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p "$tmp/deps"
cp -R "$root/test/fixtures/release_consumer" "$tmp/consumer"
cp -R "$root/deps/telemetry" "$tmp/deps/telemetry"
cp "$root/mix.lock" "$tmp/consumer/mix.lock"

export BENDLER_ROOT="$root"
export MIX_DEPS_PATH="$tmp/deps"
export MIX_ENV=prod
cd "$tmp/consumer"

mix deps.compile
mix compile

# Mix may copy priv or create it directly in the build tree when the source
# project has no priv directory. Inspect the application's canonical build
# path rather than assuming a source-tree symlink (which differed on Linux).
consumer_priv="_build/prod/lib/consumer/priv"
artifact="$consumer_priv/bendler/host/prod/consumer_calc"
test -x "$artifact"
test -x "$consumer_priv/bendler/host/prod/bendler_launcher"

# Clean only the active host/prod scope. A sentinel representing another
# target/environment must survive, while the retained request lets ordinary
# `mix compile` restore the active worker and launcher.
sentinel="$consumer_priv/bendler/other_target/other_env/keep"
mkdir -p "$(dirname "$sentinel")"
: > "$sentinel"
mix bendler.clean
test ! -e "$artifact"
test -e "$sentinel"
mix compile
test -x "$artifact"
test -x "$consumer_priv/bendler/host/prod/bendler_launcher"

mix release --overwrite --no-compile
release_priv=$(find "$tmp/consumer/_build/prod/rel/consumer/lib" -path '*/priv/bendler/host/prod/consumer_calc' -print -quit)
test -n "$release_priv"
test -x "$release_priv"
test -x "$(dirname "$release_priv")/bendler_launcher"

# No Bend executable is present while starting the release.
PATH="/usr/bin:/bin" "$tmp/consumer/_build/prod/rel/consumer/bin/consumer" eval \
  '{:ok, _} = Consumer.Calc.start_link(); IO.inspect(Consumer.Calc.add(20, 22))' | grep -qx '42'
