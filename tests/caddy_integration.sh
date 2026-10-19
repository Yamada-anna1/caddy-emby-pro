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

if ! command -v sha256sum >/dev/null 2>&1 && command -v b2sum >/dev/null 2>&1; then
    sha256sum() { b2sum "$@"; }
fi

mkdir -p "$CADDY_DIR"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

site_id="$(make_site_id "dao.example.com")"
auto_site_id="$(make_site_id "player.example.com")"
build_stream_config_block \
    "dao.example.com" \
    "db.example.com" \
    "https://api.example.com:443" \
    "https://stream.example.com:443" \
    "__dao_stream" \
    "$site_id" > "$CADDYFILE"

caddy fmt --overwrite "$CADDYFILE"
caddy validate --config "$CADDYFILE" --adapter caddyfile

diagnostic_source="$TEST_TMP/Caddyfile.discovery-source"
diagnostic_candidate="$TEST_TMP/Caddyfile.discovery-candidate"
diagnostic_existing_log="$TEST_TMP/existing-access.json"
diagnostic_capture_log="$TEST_TMP/discovery-access.json"
cat > "$diagnostic_source" <<EOF
legacy.example.com {
    log {
        output file $diagnostic_existing_log
        format json
    }

    reverse_proxy https://api.example.com {
        header_down Location "(?i)^https?://stream[.]example[.]com(:[0-9]+)?/" "https://{http.request.host}/__legacy_stream/"
    }
}
EOF
inject_discovery_log_file "$diagnostic_source" "$diagnostic_candidate" "legacy" \
    "legacy.example.com" "legacy.example.com" "$diagnostic_capture_log"
caddy validate --config "$diagnostic_candidate" --adapter caddyfile
! grep -Fq "$diagnostic_existing_log" "$diagnostic_candidate" \
    || fail "diagnostic candidate retained the target site's existing access log"
grep -Fq "$diagnostic_capture_log" "$diagnostic_candidate" \
    || fail "diagnostic candidate did not install the temporary access log"
! grep -Fq 'header_down Location' "$diagnostic_candidate" \
    || fail "diagnostic candidate retained Location rewriting and hid the real stream origin"

proxy_port="${CADDY_TEST_PROXY_PORT:-28080}"
api_port="${CADDY_TEST_API_PORT:-28081}"
stream_port="${CADDY_TEST_STREAM_PORT:-28082}"
stream_b_port="${CADDY_TEST_STREAM_B_PORT:-28083}"
runtime_caddyfile="$TEST_TMP/Caddyfile.runtime"
runtime_log="$TEST_TMP/caddy-runtime.log"
second_prefix="$(stream_route_prefix '__dao_stream' 1 'localhost')"
auto_second_prefix="$(stream_route_prefix '__player_stream' 1 'localhost')"

{
    printf '%s\n' '{' '    admin off' '}' ''
    build_stream_config_block \
        "dao.example.com" \
        "db.example.com" \
        "http://127.0.0.1:$api_port" \
        "http://127.0.0.1:$stream_port,http://localhost:$stream_b_port" \
        "__dao_stream" \
        "$site_id" \
        | sed \
            -e "s/^db[.]example[.]com {/http:\/\/db.example.com:$proxy_port {/" \
            -e "s/^dao[.]example[.]com {/http:\/\/dao.example.com:$proxy_port {/" \
            -e 's#https://{http.request.host}/#http://{http.request.host}/#g'
    printf '\n'
    build_auto_stream_config_block \
        "player.example.com" \
        "http://127.0.0.1:$api_port" \
        "http://127.0.0.1:$stream_port,http://localhost:$stream_b_port" \
        "__player_stream" \
        "$auto_site_id" \
        | sed \
            -e "s/^player[.]example[.]com {/http:\/\/player.example.com:$proxy_port {/" \
            -e 's#https://{http.request.host}/#http://{http.request.host}/#g'
    printf '\nhttp://127.0.0.1:%s {\n' "$api_port"
    printf '    @stream_a path /redirect/a\n'
    printf '    redir @stream_a "http://127.0.0.1:%s/stream/a.mkv?sig=a" 302\n' "$stream_port"
    printf '    @stream_b path /redirect/b\n'
    printf '    redir @stream_b "http://localhost:%s/stream/b.mkv?sig=b" 302\n' "$stream_b_port"
    printf '    respond "api {http.request.uri}"\n}\n'
    printf '\nhttp://127.0.0.1:%s {\n    respond "stream-a {http.request.uri} range={http.request.header.Range}"\n}\n' "$stream_port"
    printf '\nhttp://localhost:%s {\n' "$stream_b_port"
    printf '    @hop path /hop-to-a\n'
    printf '    redir @hop "http://127.0.0.1:%s/stream/final.mkv?sig=chain" 302\n' "$stream_port"
    printf '    respond "stream-b {http.request.uri} range={http.request.header.Range}"\n}\n'
} > "$runtime_caddyfile"

caddy validate --config "$runtime_caddyfile" --adapter caddyfile
caddy run --config "$runtime_caddyfile" --adapter caddyfile > "$runtime_log" 2>&1 &
CADDY_TEST_PID=$!

front_resolve="dao.example.com:$proxy_port:127.0.0.1"
route_resolve="db.example.com:$proxy_port:127.0.0.1"
auto_resolve="player.example.com:$proxy_port:127.0.0.1"
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
    || fail "pathless client request did not reach the API upstream unchanged"

legacy_response="$(curl -fsS --noproxy '*' --resolve "$front_resolve" \
    "http://dao.example.com:$proxy_port/db.example.com/emby/Items/1?x=2")"
[[ "$legacy_response" == 'api /emby/Items/1?x=2' ]] \
    || fail "compatibility path was not stripped before reaching the API upstream"

route_response="$(curl -fsS --noproxy '*' --resolve "$route_resolve" \
    "http://db.example.com:$proxy_port/emby/Items/2?x=3")"
[[ "$route_response" == 'api /emby/Items/2?x=3' ]] \
    || fail "compatibility domain did not reach the API upstream unchanged"

stream_response="$(curl -fsS --noproxy '*' --resolve "$front_resolve" \
    -H 'Range: bytes=0-0' \
    "http://dao.example.com:$proxy_port/__dao_stream/stream/file.mkv?sig=abc")"
[[ "$stream_response" == 'stream-a /stream/file.mkv?sig=abc range=bytes=0-0' ]] \
    || fail "internal stream path did not take priority over the API fallback"

stream_b_response="$(curl -fsS --noproxy '*' --resolve "$route_resolve" \
    -H 'Range: bytes=10-20' \
    "http://db.example.com:$proxy_port/$second_prefix/stream/file.mkv?sig=def")"
[[ "$stream_b_response" == 'stream-b /stream/file.mkv?sig=def range=bytes=10-20' ]] \
    || fail "second stream node did not preserve route-domain Range or signature"

redirect_a_headers="$(curl -sS --noproxy '*' --resolve "$front_resolve" \
    --max-redirs 0 -D - -o /dev/null \
    "http://dao.example.com:$proxy_port/redirect/a" | tr -d '\r')"
grep -Fqi "location: http://dao.example.com/__dao_stream/stream/a.mkv?sig=a" \
    <<< "$redirect_a_headers" \
    || fail "first stream Location was not rewritten to the requesting front domain"

redirect_b_headers="$(curl -sS --noproxy '*' --resolve "$route_resolve" \
    --max-redirs 0 -D - -o /dev/null \
    "http://db.example.com:$proxy_port/redirect/b" | tr -d '\r')"
grep -Fqi "location: http://db.example.com/$second_prefix/stream/b.mkv?sig=b" \
    <<< "$redirect_b_headers" \
    || fail "second stream Location was not rewritten to the requesting compatibility domain"

chain_headers="$(curl -sS --noproxy '*' --resolve "$front_resolve" \
    --max-redirs 0 -D - -o /dev/null \
    "http://dao.example.com:$proxy_port/$second_prefix/hop-to-a" | tr -d '\r')"
grep -Fqi "location: http://dao.example.com/__dao_stream/stream/final.mkv?sig=chain" \
    <<< "$chain_headers" \
    || fail "secondary stream redirect escaped the VPS"

auto_root_response="$(curl -fsS --noproxy '*' --resolve "$auto_resolve" \
    "http://player.example.com:$proxy_port/emby/System/Info/Public?token=auto")"
[[ "$auto_root_response" == 'api /emby/System/Info/Public?token=auto' ]] \
    || fail "auto-upgraded site root did not reach the API upstream unchanged"

auto_redirect_headers="$(curl -sS --noproxy '*' --resolve "$auto_resolve" \
    --max-redirs 0 -D - -o /dev/null \
    "http://player.example.com:$proxy_port/redirect/a" | tr -d '\r')"
grep -Fqi 'location: http://player.example.com/__player_stream/stream/a.mkv?sig=a' \
    <<< "$auto_redirect_headers" \
    || fail "auto-upgraded site did not rewrite the playback redirect"

auto_stream_response="$(curl -fsS --noproxy '*' --resolve "$auto_resolve" \
    -H 'Range: bytes=20-30' \
    "http://player.example.com:$proxy_port/$auto_second_prefix/stream/file.mkv?sig=auto")"
[[ "$auto_stream_response" == 'stream-b /stream/file.mkv?sig=auto range=bytes=20-30' ]] \
    || fail "auto-upgraded site did not preserve the secondary stream Range or signature"

auto_chain_headers="$(curl -sS --noproxy '*' --resolve "$auto_resolve" \
    --max-redirs 0 -D - -o /dev/null \
    "http://player.example.com:$proxy_port/$auto_second_prefix/hop-to-a" | tr -d '\r')"
grep -Fqi 'location: http://player.example.com/__player_stream/stream/final.mkv?sig=chain' \
    <<< "$auto_chain_headers" \
    || fail "auto-upgraded site secondary redirect escaped the VPS"

redirect_headers="$(curl -sS --noproxy '*' --resolve "$front_resolve" \
    --max-redirs 0 -D - -o /dev/null \
    "http://dao.example.com:$proxy_port/db.example.com" | tr -d '\r')"
grep -Eq '^HTTP/[0-9.]+ 308' <<< "$redirect_headers" \
    || fail "compatibility path root did not return HTTP 308"
grep -Fqi 'location: /db.example.com/' <<< "$redirect_headers" \
    || fail "compatibility path root redirect target is incorrect"

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
