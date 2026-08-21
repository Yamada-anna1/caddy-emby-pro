#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
CADDY_TEST_PID=""

cleanup() {
    if [[ -n "$CADDY_TEST_PID" ]] && kill -0 "$CADDY_TEST_PID" 2>/dev/null; then
        kill "$CADDY_TEST_PID" 2>/dev/null || true
        wait "$CADDY_TEST_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

export CADDY_EMBY_SOURCE_ONLY=1
export CADDY_DIR="$TEST_TMP/etc/caddy"
export CADDYFILE="$CADDY_DIR/Caddyfile"
export BACKUP_DIR="$TEST_TMP/backups"

# shellcheck disable=SC1091
source "$ROOT_DIR/install_caddy_emby.sh"

mkdir -p "$CADDY_DIR"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

site_id="$(make_site_id "dao.example.com")"
build_stream_config_block \
    "dao.example.com" \
    "db.example.com" \
    "https://api.example.com:443" \
    "https://stream.example.com:443" \
    "__dao_stream" \
    "$site_id" > "$CADDYFILE"

caddy fmt --overwrite "$CADDYFILE"
caddy validate --config "$CADDYFILE" --adapter caddyfile

proxy_port="${CADDY_TEST_PROXY_PORT:-28080}"
api_port="${CADDY_TEST_API_PORT:-28081}"
stream_port="${CADDY_TEST_STREAM_PORT:-28082}"
runtime_caddyfile="$TEST_TMP/Caddyfile.runtime"
runtime_log="$TEST_TMP/caddy-runtime.log"

{
    printf '%s\n' '{' '    admin off' '}' ''
    build_stream_config_block \
        "dao.example.com" \
        "db.example.com" \
        "http://127.0.0.1:$api_port" \
        "http://127.0.0.1:$stream_port" \
        "__dao_stream" \
        "$site_id" \
        | sed \
            -e "s/^db[.]example[.]com {/http:\/\/db.example.com:$proxy_port {/" \
            -e "s/^dao[.]example[.]com {/http:\/\/dao.example.com:$proxy_port {/"
    printf '\nhttp://127.0.0.1:%s {\n    respond "api {http.request.uri}"\n}\n' "$api_port"
    printf '\nhttp://127.0.0.1:%s {\n    respond "stream {http.request.uri}"\n}\n' "$stream_port"
} > "$runtime_caddyfile"

caddy validate --config "$runtime_caddyfile" --adapter caddyfile
caddy run --config "$runtime_caddyfile" --adapter caddyfile > "$runtime_log" 2>&1 &
CADDY_TEST_PID=$!

front_resolve="dao.example.com:$proxy_port:127.0.0.1"
route_resolve="db.example.com:$proxy_port:127.0.0.1"
runtime_ready=false
for _ in {1..50}; do
    if ! kill -0 "$CADDY_TEST_PID" 2>/dev/null; then
        cat "$runtime_log" >&2
        fail "runtime Caddy exited before becoming ready"
    fi
    if curl -fsS --noproxy '*' --resolve "$front_resolve" \
        "http://dao.example.com:$proxy_port/ready" >/dev/null 2>&1; then
        runtime_ready=true
        break
    fi
    sleep 0.1
done
[[ "$runtime_ready" == "true" ]] || {
    cat "$runtime_log" >&2
    fail "runtime Caddy did not become ready"
}

root_response="$(curl -fsS --noproxy '*' --resolve "$front_resolve" \
    "http://dao.example.com:$proxy_port/emby/System/Info/Public?token=a")"
[[ "$root_response" == 'api /emby/System/Info/Public?token=a' ]] \
    || fail "pathless Hills request did not reach the API upstream unchanged"

legacy_response="$(curl -fsS --noproxy '*' --resolve "$front_resolve" \
    "http://dao.example.com:$proxy_port/db.example.com/emby/Items/1?x=2")"
[[ "$legacy_response" == 'api /emby/Items/1?x=2' ]] \
    || fail "legacy Hills path was not stripped before reaching the API upstream"

route_response="$(curl -fsS --noproxy '*' --resolve "$route_resolve" \
    "http://db.example.com:$proxy_port/emby/Items/2?x=3")"
[[ "$route_response" == 'api /emby/Items/2?x=3' ]] \
    || fail "compatibility domain did not reach the API upstream unchanged"

stream_response="$(curl -fsS --noproxy '*' --resolve "$front_resolve" \
    "http://dao.example.com:$proxy_port/__dao_stream/stream/file.mkv?sig=abc")"
[[ "$stream_response" == 'stream /stream/file.mkv?sig=abc' ]] \
    || fail "internal stream path did not take priority over the API fallback"

redirect_headers="$(curl -sS --noproxy '*' --resolve "$front_resolve" \
    --max-redirs 0 -D - -o /dev/null \
    "http://dao.example.com:$proxy_port/db.example.com" | tr -d '\r')"
grep -Eq '^HTTP/[0-9.]+ 308' <<< "$redirect_headers" \
    || fail "legacy path root did not return HTTP 308"
grep -Fqi 'location: /db.example.com/' <<< "$redirect_headers" \
    || fail "legacy path root redirect target is incorrect"

kill "$CADDY_TEST_PID" 2>/dev/null || true
wait "$CADDY_TEST_PID" 2>/dev/null || true
CADDY_TEST_PID=""

mkdir -p "$CADDY_DIR/sites"
cat > "$CADDY_DIR/sites/imported.caddy" <<'EOF'
https://TARGET.EXAMPLE.COM:443 {
    respond "target"
}

one.example.com, two.example.com {
    respond "multi"
}

:443 {
    @nested host NESTED.EXAMPLE.COM
    handle @nested {
        respond "nested"
    }
}
EOF

printf '%s\n' 'import sites/*.caddy' > "$CADDYFILE"

domain_conflict_in_file "$CADDYFILE" "target.example.com" \
    || fail "scheme/port/case conflict was not detected through import"
domain_conflict_in_file "$CADDYFILE" "two.example.com" \
    || fail "multi-address conflict was not detected through import"
domain_conflict_in_file "$CADDYFILE" "nested.example.com" \
    || fail "nested handle host conflict was not detected through import"
if domain_conflict_in_file "$CADDYFILE" "free.example.com"; then
    fail "free domain was reported as occupied"
else
    status=$?
fi
(( status == 1 )) || fail "free domain check returned an error"

printf 'Caddy integration tests passed.\n'
