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
