#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

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

assert_contains() {
    local haystack="$1"
    local needle="$2"
    grep -Fq "$needle" <<< "$haystack" || fail "missing: $needle"
}

validate_domain "dao.example.com" || fail "valid domain rejected"
! validate_domain "https://dao.example.com" || fail "invalid domain accepted"
validate_upstream_url "https://stream.example.com:443" || fail "valid upstream rejected"
! validate_upstream_url "stream.example.com:443/path" || fail "invalid upstream accepted"
valid_menu_choice 10 || fail "menu choice 10 rejected"
! valid_menu_choice 11 || fail "menu choice 11 accepted"

site_id="$(make_site_id "dao.example.com")"
[[ "$site_id" == "$(make_site_id "dao.example.com")" ]] || fail "site id is not stable"

block="$(build_stream_config_block \
    "dao.example.com" \
    "db.example.com" \
    "https://api.example.com:443" \
    "https://stream.example.com:443" \
    "__dao_stream" \
    "$site_id")"

assert_contains "$block" "$STREAM_BEGIN dao.example.com db.example.com"
assert_contains "$block" "(${site_id}_api)"
assert_contains "$block" "(${site_id}_stream)"
assert_contains "$block" 'header_down Location "(?i)^https?://stream[.]example[.]com(?::[0-9]+)?" "https://dao.example.com/__dao_stream"'
assert_contains "$block" "handle_path /db.example.com/*"
assert_contains "$block" "handle_path /__dao_stream/*"
assert_contains "$block" "$STREAM_END dao.example.com"

printf '%s\n\n%s\n' "$block" 'keep.example.com {' > "$CADDYFILE"
printf '%s\n' '    reverse_proxy 127.0.0.1:8096' '}' >> "$CADDYFILE"
check_managed_markers "$CADDYFILE" || fail "valid markers rejected"

without_stream="$TEST_TMP/without-stream"
remove_stream_group_file "$CADDYFILE" "$without_stream" "dao.example.com" || fail "stream group removal failed"
! grep -Fq "dao.example.com" "$without_stream" || fail "stream group remained"
grep -Fq "keep.example.com" "$without_stream" || fail "unrelated site removed"

legacy="$TEST_TMP/legacy"
cat > "$legacy" <<'EOF'
legacy.example.com {
    reverse_proxy https://upstream.example.com {
        header_up Host {upstream_hostport}
    }
}

keep.example.com {
    reverse_proxy 127.0.0.1:8096
}
EOF

without_legacy="$TEST_TMP/without-legacy"
remove_site_block_file "$legacy" "$without_legacy" "legacy.example.com" || fail "legacy removal failed"
! grep -Fq "legacy.example.com" "$without_legacy" || fail "legacy block remained"
grep -Fq "keep.example.com" "$without_legacy" || fail "next block was damaged"

broken="$TEST_TMP/broken"
printf '%s\n' "$STREAM_BEGIN dao.example.com db.example.com" > "$broken"
! check_managed_markers "$broken" || fail "broken marker accepted"

printf 'All tests passed.\n'
