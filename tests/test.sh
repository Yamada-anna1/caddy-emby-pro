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
    [[ "$haystack" == *"$needle"* ]] || fail "missing: $needle"
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
assert_contains "$block" 'header_down Location "(?i)^https?://stream[.]example[.]com(:[0-9]+)?/" "https://dao.example.com/__dao_stream/"'
! grep -Fq '(?:' <<< "$block" \
    || fail "stream Location regex contains a Go-incompatible non-capturing group"
assert_contains "$block" "    handle_path /db.example.com/* {
        import ${site_id}_api
    }"
assert_contains "$block" "    handle_path /__dao_stream/* {
        import ${site_id}_stream
    }"
assert_contains "$block" "    handle {
        import ${site_id}_api
    }"
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

adapted_hosts="$TEST_TMP/adapted-hosts.json"
cat > "$adapted_hosts" <<'EOF'
{
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "routes": [
            {"match": [{"host": ["one.example.com", "TARGET.EXAMPLE.COM", "*.wild.example.com"]}]},
            {
              "handle": [{
                "handler": "subroute",
                "routes": [
                  {"match": [{"host": ["NESTED.EXAMPLE.COM"]}]}
                ]
              }]
            }
          ]
        }
      }
    }
  }
}
EOF

adapted_json_contains_domain "$adapted_hosts" "target.example.com" \
    || fail "case-insensitive adapted host conflict missed"
adapted_json_contains_domain "$adapted_hosts" "video.wild.example.com" \
    || fail "wildcard adapted host conflict missed"
adapted_json_contains_domain "$adapted_hosts" "nested.example.com" \
    || fail "nested subroute host conflict missed"
! adapted_json_contains_domain "$adapted_hosts" "free.example.com" \
    || fail "free adapted host reported as conflict"

MOCK_CADDY_FMT_RC=0
MOCK_CADDY_VALIDATE_RC=0
MOCK_CADDY_ADAPT_RC=0
MOCK_ADAPTED_JSON='{"apps":{"http":{"servers":{"srv0":{"routes":[{}]}}}}}'
MOCK_ACTIVE=false
MOCK_PID=100
MOCK_RESTART_CALLS=0
MOCK_RESTART_RESULTS=(0)
MOCK_RESTART_MUTATIONS=()
MOCK_SYSTEMCTL_LOG="$TEST_TMP/systemctl.log"
MOCK_RESTART_SHA_LOG="$TEST_TMP/restart-sha.log"
MOCK_ACTIVE_STATE_OVERRIDE=""
: > "$MOCK_SYSTEMCTL_LOG"
: > "$MOCK_RESTART_SHA_LOG"

caddy() {
    case "${1-}" in
        fmt)
            [[ "${2-}" == "--overwrite" && -n "${3-}" ]] || return 98
            return "$MOCK_CADDY_FMT_RC"
            ;;
        validate)
            [[ "${2-}" == "--config" && -n "${3-}" \
                && "${4-}" == "--adapter" && "${5-}" == "caddyfile" ]] || return 98
            return "$MOCK_CADDY_VALIDATE_RC"
            ;;
        adapt)
            [[ "${2-}" == "--config" && -n "${3-}" \
                && "${4-}" == "--adapter" && "${5-}" == "caddyfile" ]] || return 98
            printf '%s\n' "$MOCK_ADAPTED_JSON"
            return "$MOCK_CADDY_ADAPT_RC"
            ;;
    esac
    return 0
}

systemctl() {
    local index result mutation
    printf '%s\n' "$*" >> "$MOCK_SYSTEMCTL_LOG"
    case "${1-}" in
        is-active)
            [[ "$*" == "is-active --quiet caddy" ]] || return 99
            if [[ "$MOCK_ACTIVE" == "true" ]]; then
                return 0
            fi
            return 1
            ;;
        show)
            if [[ "$*" == "show -p MainPID --value caddy" ]]; then
                printf '%s\n' "$MOCK_PID"
            elif [[ "$*" == "show -p ActiveState --value caddy" ]]; then
                if [[ -n "$MOCK_ACTIVE_STATE_OVERRIDE" ]]; then
                    printf '%s\n' "$MOCK_ACTIVE_STATE_OVERRIDE"
                elif [[ "$MOCK_ACTIVE" == "true" ]]; then
                    printf 'active\n'
                else
                    printf 'inactive\n'
                fi
            else
                return 99
            fi
            return 0
            ;;
        restart)
            [[ "$*" == "restart caddy" ]] || return 99
            if [[ -f "$CADDYFILE" ]]; then
                config_sha256 "$CADDYFILE" >> "$MOCK_RESTART_SHA_LOG"
            else
                printf 'missing\n' >> "$MOCK_RESTART_SHA_LOG"
            fi
            index="$MOCK_RESTART_CALLS"
            MOCK_RESTART_CALLS=$((MOCK_RESTART_CALLS + 1))
            result="${MOCK_RESTART_RESULTS[$index]:-0}"
            mutation="${MOCK_RESTART_MUTATIONS[$index]-}"
            if [[ -n "$mutation" ]]; then
                printf '%s\n' "$mutation" > "$CADDYFILE"
            fi
            if (( result == 0 )); then
                MOCK_ACTIVE=true
                MOCK_ACTIVE_STATE_OVERRIDE=""
                MOCK_PID=$((MOCK_PID + 1))
            fi
            return "$result"
            ;;
        stop)
            [[ "$*" == "stop caddy" ]] || return 99
            MOCK_ACTIVE=false
            MOCK_ACTIVE_STATE_OVERRIDE=""
            return 0
            ;;
    esac
    return 99
}

chown() { return 0; }

COPY_CONFIG_SHOULD_FAIL=false
cp() {
    local destination="${*: -1}"
    if [[ "$COPY_CONFIG_SHOULD_FAIL" == "true" && "$destination" == *'.Caddyfile.candidate.'* ]]; then
        return 74
    fi
    command cp "$@"
}

conflict_source="$TEST_TMP/conflict-source"
printf '%s\n' 'import sites/*.caddy' > "$conflict_source"
MOCK_ADAPTED_JSON='{"apps":{"http":{"servers":{"srv0":{"routes":[{"match":[{"host":["OTHER.EXAMPLE.COM","dao.example.com"]}]}]}}}}}'
if domain_conflict_in_file "$conflict_source" "DAO.EXAMPLE.COM"; then
    conflict_status=0
else
    conflict_status=$?
fi
(( conflict_status == 0 )) || fail "adapted/imported domain conflict missed"

MOCK_CADDY_ADAPT_RC=1
if domain_conflict_in_file "$conflict_source" "dao.example.com"; then
    conflict_status=0
else
    conflict_status=$?
fi
(( conflict_status == 2 )) || fail "adapt failure was treated as a free domain"
MOCK_CADDY_ADAPT_RC=0

missing_conflict_file="$TEST_TMP/does-not-exist"
if domain_conflict_in_file "$missing_conflict_file" "dao.example.com"; then
    conflict_status=0
else
    conflict_status=$?
fi
(( conflict_status == 2 )) || fail "missing config was treated as a free domain"

reset_transaction_case() {
    local case_name="$1"
    CADDY_DIR="$TEST_TMP/transactions/$case_name/etc/caddy"
    CADDYFILE="$CADDY_DIR/Caddyfile"
    BACKUP_DIR="$TEST_TMP/transactions/$case_name/backups"
    mkdir -p "$CADDY_DIR"
    LAST_BACKUP=""
    MOCK_CADDY_FMT_RC=0
    MOCK_CADDY_VALIDATE_RC=0
    MOCK_CADDY_ADAPT_RC=0
    MOCK_ADAPTED_JSON='{"apps":{"http":{"servers":{"srv0":{"routes":[{}]}}}}}'
    MOCK_ACTIVE=true
    MOCK_PID=100
    MOCK_RESTART_CALLS=0
    MOCK_RESTART_RESULTS=(0)
    MOCK_RESTART_MUTATIONS=()
    MOCK_ACTIVE_STATE_OVERRIDE=""
    : > "$MOCK_SYSTEMCTL_LOG"
    : > "$MOCK_RESTART_SHA_LOG"
}

reset_transaction_case "validate-failure"
printf '%s\n' 'old.example.com {' '    respond "old"' '}' > "$CADDYFILE"
validate_snapshot="$TEST_TMP/validate-snapshot"
command cp "$CADDYFILE" "$validate_snapshot"
validate_candidate="$(new_candidate_file)"
printf '%s\n' 'new.example.com {' '    respond "new"' '}' > "$validate_candidate"
MOCK_CADDY_VALIDATE_RC=65
if apply_candidate "$validate_candidate"; then
    fail "validate failure was reported as success"
else
    apply_status=$?
fi
(( apply_status != 0 )) || fail "validate failure returned zero"
cmp -s "$validate_snapshot" "$CADDYFILE" || fail "validate failure modified Caddyfile"
[[ ! -e "$validate_candidate" ]] || fail "invalid candidate was not removed"
[[ ! -d "$BACKUP_DIR" ]] || fail "validate failure created a backup"
[[ ! -s "$MOCK_SYSTEMCTL_LOG" ]] || fail "validate failure touched systemd"

reset_transaction_case "backup-failure"
printf '%s\n' 'old.example.com {' '    respond "old"' '}' > "$CADDYFILE"
backup_snapshot="$TEST_TMP/backup-snapshot"
command cp "$CADDYFILE" "$backup_snapshot"
backup_candidate="$(new_candidate_file)"
printf '%s\n' 'new.example.com {' '    respond "new"' '}' > "$backup_candidate"
backup_blocker="$TEST_TMP/transactions/backup-failure/not-a-directory"
touch "$backup_blocker"
BACKUP_DIR="$backup_blocker/backups"
if apply_candidate "$backup_candidate"; then
    fail "backup failure was reported as success"
else
    apply_status=$?
fi
(( apply_status != 0 )) || fail "backup failure returned zero"
cmp -s "$backup_snapshot" "$CADDYFILE" || fail "backup failure modified Caddyfile"
[[ ! -e "$backup_candidate" ]] || fail "candidate remained after backup failure"
! grep -q '^restart ' "$MOCK_SYSTEMCTL_LOG" || fail "backup failure restarted Caddy"

reset_transaction_case "restart-failure"
printf '%s\n' 'old.example.com {' '    respond "old"' '}' > "$CADDYFILE"
restart_snapshot="$TEST_TMP/restart-snapshot"
command cp "$CADDYFILE" "$restart_snapshot"
restart_candidate="$(new_candidate_file)"
printf '%s\n' 'new.example.com {' '    respond "new"' '}' > "$restart_candidate"
restart_new_sha="$(config_sha256 "$restart_candidate")"
restart_old_sha="$(config_sha256 "$restart_snapshot")"
MOCK_RESTART_RESULTS=(1 0)
if apply_candidate "$restart_candidate"; then
    fail "restart failure was reported as success"
else
    apply_status=$?
fi
(( apply_status == 1 )) || fail "recovered restart failure returned unexpected status"
cmp -s "$restart_snapshot" "$CADDYFILE" || fail "restart failure did not restore Caddyfile"
(( MOCK_RESTART_CALLS == 2 )) || fail "restart failure did not reapply restored config"
mapfile -t restart_hashes < "$MOCK_RESTART_SHA_LOG"
[[ "${restart_hashes[0]-}" == "$restart_new_sha" ]] \
    || fail "first restart did not see the new config"
[[ "${restart_hashes[1]-}" == "$restart_old_sha" ]] \
    || fail "rollback restart did not see the restored config"
[[ ! -e "$restart_candidate" ]] || fail "installed candidate still exists"
[[ -n "$LAST_BACKUP" && -f "$LAST_BACKUP" ]] || fail "restart rollback backup missing"
cmp -s "$restart_snapshot" "$LAST_BACKUP" || fail "restart rollback backup is invalid"
[[ "$MOCK_ACTIVE" == "true" ]] || fail "restart rollback did not restore active service"

reset_transaction_case "external-change-before-rollback"
printf '%s\n' 'old.example.com {' '    respond "old"' '}' > "$CADDYFILE"
external_candidate="$(new_candidate_file)"
printf '%s\n' 'new.example.com {' '    respond "new"' '}' > "$external_candidate"
MOCK_RESTART_RESULTS=(1)
MOCK_RESTART_MUTATIONS=('external.example.com { respond "external" }')
if apply_candidate "$external_candidate"; then
    fail "external modification during restart failure was reported as success"
else
    apply_status=$?
fi
(( apply_status == 2 )) || fail "external modification did not produce a severe rollback status"
grep -Fqx 'external.example.com { respond "external" }' "$CADDYFILE" \
    || fail "rollback overwrote an external Caddyfile modification"
(( MOCK_RESTART_CALLS == 1 )) || fail "unsafe rollback unexpectedly restarted Caddy"
[[ -n "$LAST_BACKUP" && -f "$LAST_BACKUP" ]] \
    || fail "old config backup was not preserved after rollback refusal"

reset_transaction_case "unknown-service-state"
printf '%s\n' 'old.example.com {' '    respond "old"' '}' > "$CADDYFILE"
unknown_state_snapshot="$TEST_TMP/unknown-state-snapshot"
command cp "$CADDYFILE" "$unknown_state_snapshot"
unknown_state_candidate="$(new_candidate_file)"
printf '%s\n' 'new.example.com {' '    respond "new"' '}' > "$unknown_state_candidate"
MOCK_ACTIVE_STATE_OVERRIDE="activating"
if apply_candidate "$unknown_state_candidate"; then
    fail "transitional service state was treated as safe"
else
    apply_status=$?
fi
(( apply_status != 0 )) || fail "transitional service state returned zero"
cmp -s "$unknown_state_snapshot" "$CADDYFILE" \
    || fail "transitional service state modified Caddyfile"
[[ ! -d "$BACKUP_DIR" ]] || fail "transitional service state created a backup"

copy_source="$TEST_TMP/copy-source"
copy_candidate="$TEST_TMP/.Caddyfile.candidate.copy-test"
printf 'preserve me\n' > "$copy_source"
COPY_CONFIG_SHOULD_FAIL=true
if copy_config_to_candidate "$copy_source" "$copy_candidate"; then
    fail "candidate copy failure was reported as success"
else
    copy_status=$?
fi
(( copy_status != 0 )) || fail "candidate copy failure returned zero"
grep -Fqx 'preserve me' "$copy_source" || fail "candidate copy failure damaged source"
unset -f cp

prune_case="$TEST_TMP/prune-backups"
mkdir -p "$prune_case"
for index in 1 2 3 4 5; do
    printf 'future\n' > "$prune_case/Caddyfile.2099010${index}-000000-000000000.future${index}.bak"
done
current_backup="$prune_case/Caddyfile.20000101-000000-000000000.current.bak"
printf 'current\n' > "$current_backup"
touch -t 199901010000 "$current_backup"
BACKUP_DIR="$prune_case"
LAST_BACKUP="$current_backup"
prune_old_backups
[[ -f "$current_backup" ]] || fail "current backup was pruned after a system clock rollback"
backup_count="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'Caddyfile.*.bak' | wc -l)"
(( backup_count == 5 )) || fail "backup pruning did not keep exactly five files"

reset_transaction_case "dangling-symlink"
rm -f "$CADDYFILE"
ln -s "$CADDY_DIR/missing-target" "$CADDYFILE"
symlink_candidate="$(new_candidate_file)"
printf '%s\n' 'new.example.com {' '    respond "new"' '}' > "$symlink_candidate"
MOCK_ACTIVE=false
if apply_candidate "$symlink_candidate"; then
    fail "dangling Caddyfile symlink was overwritten"
else
    apply_status=$?
fi
(( apply_status != 0 )) || fail "dangling symlink rejection returned zero"
[[ -L "$CADDYFILE" ]] || fail "dangling Caddyfile symlink was changed"

reset_transaction_case "propagate-failure"
rm -f "$CADDYFILE"
apply_candidate() { return 37; }
if commit_stream_proxy_config \
    "dao.example.com" \
    "db.example.com" \
    "https://api.example.com:443" \
    "https://stream.example.com:443" \
    "__dao_stream" \
    "$(make_site_id "dao.example.com")"; then
    fail "stream commit swallowed apply failure"
else
    apply_status=$?
fi
(( apply_status == 37 )) || fail "stream commit did not propagate apply failure"

printf 'All tests passed.\n'
