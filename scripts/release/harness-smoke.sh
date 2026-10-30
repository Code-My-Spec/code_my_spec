#!/usr/bin/env bash
# Run the shipped artifact without a checkout, toolchain, credentials or network.
set -euo pipefail
archive=${1:?Pass the harness tarball}
work=$(mktemp -d)
pid=
cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/release" "$work/state"
tar -xzf "$archive" -C "$work/release"
export CMS_STATE_DIR="$work/state" CMS_SERVER_URL=http://127.0.0.1:9
export CMS_HARNESS_PORT=4004 ERL_FLAGS='+S 2:2'
unset CMS_PROJECT_DIR CMS_CLOUD_PROJECT_ROOT CMS_DEV_BOX
cd "$work/release"
# Loading both crypto and SQLite exercises native dependencies as well as ERTS.
bin/cms_harness eval '{:ok, _} = Application.ensure_all_started(:crypto); :crypto.strong_rand_bytes(8); {:ok, db} = Exqlite.Sqlite3.open(":memory:"); :ok = Exqlite.Sqlite3.close(db); IO.puts("NATIVE_RUNTIME_PASSED")'
bin/cms_harness start > "$work/startup.log" 2>&1 &
pid=$!
for attempt in $(seq 1 60); do
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$work/startup.log" >&2
    echo 'Packaged harness exited before its health endpoint became available' >&2
    exit 1
  fi
  if curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:4004/health > "$work/health.json"; then
    cat "$work/health.json"
    echo
    echo HARNESS_STARTUP_PASSED
    exit 0
  fi
  sleep 1
done
cat "$work/startup.log" >&2
echo 'Packaged harness did not serve /health within 60 seconds' >&2
exit 1
