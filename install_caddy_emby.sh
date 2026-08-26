#!/usr/bin/env bash

# ====================================================
#  Caddy Reverse Proxy for Emby - V6 Pro
#  Original author: AiLi1337
#  Multi-site stream proxy extension: Yamada-anna1
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

SCRIPT_URL="https://raw.githubusercontent.com/Yamada-anna1/caddy-emby-pro/main/install_caddy_emby.sh"
SCRIPT_DEST="/usr/local/bin/caddy_emby.sh"
SHORTCUT="/usr/local/bin/c"

CADDY_DIR="${CADDY_DIR:-/etc/caddy}"
CADDYFILE="${CADDYFILE:-$CADDY_DIR/Caddyfile}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/caddy-emby-pro}"
STREAM_BEGIN="# BEGIN CADDY_EMBY_STREAM"
STREAM_END="# END CADDY_EMBY_STREAM"
SITE_BEGIN="# BEGIN CADDY_EMBY_SITE"
SITE_END="# END CADDY_EMBY_SITE"

LAST_BACKUP=""

log()   { echo -e "${GREEN}[Info]${PLAIN} $1"; }
warn()  { echo -e "${YELLOW}[Warning]${PLAIN} $1"; }
error() { echo -e "${RED}[Error]${PLAIN} $1"; }


register_shortcut() {
    local src="${BASH_SOURCE[0]}"

    if [[ -f "$src" && "$src" != /proc/* && "$src" != /dev/fd/* ]]; then
        cp "$src" "$SCRIPT_DEST"
        chmod +x "$SCRIPT_DEST"
        log "脚本已保存到 $SCRIPT_DEST"
    else
        log "检测到管道运行，正在从远程下载脚本到 $SCRIPT_DEST ..."
        if curl -fsSL --retry 3 "$SCRIPT_URL" -o "$SCRIPT_DEST"; then
            chmod +x "$SCRIPT_DEST"
            log "下载成功！"
        else
            error "下载失败，请检查网络或手动保存脚本到 $SCRIPT_DEST"
            return 1
        fi
    fi

    if [[ ! -f "$SHORTCUT" ]]; then
        printf '#!/usr/bin/env bash\nbash "%s"\n' "$SCRIPT_DEST" > "$SHORTCUT"
        chmod +x "$SHORTCUT"
        log "已注册快捷命令：下次直接输入 c 即可启动本脚本"
    fi

    if ! grep -q "alias c=" /root/.bashrc 2>/dev/null; then
        echo "alias c='bash $SCRIPT_DEST'" >> /root/.bashrc
        log "已写入 alias，重新登录后也可用 c 唤出脚本"
    fi
}


install_base() {
    log "正在检查基础组件..."

    local packages=("curl" "wget" "sudo" "socat" "net-tools" "psmisc" "sed" "grep" "gawk" "jq" "coreutils" "util-linux")
    local to_install=()
    local pkg

    if [[ -f /etc/debian_version ]]; then
        for pkg in "${packages[@]}"; do
            if ! dpkg -s "$pkg" 2>/dev/null | grep -q "^Status: install ok installed"; then
                to_install+=("$pkg")
            else
                log "$pkg 已安装，跳过"
            fi
        done

        if (( ${#to_install[@]} > 0 )); then
            log "正在安装缺失的包: ${to_install[*]}"
            apt update -y && apt install -y "${to_install[@]}"
        else
            log "所有基础组件已安装"
        fi
    elif [[ -f /etc/redhat-release ]]; then
        for pkg in "${packages[@]}"; do
            if ! rpm -q "$pkg" &>/dev/null; then
                to_install+=("$pkg")
            else
                log "$pkg 已安装，跳过"
            fi
        done

        if (( ${#to_install[@]} > 0 )); then
            log "正在安装缺失的包: ${to_install[*]}"
            yum install -y "${to_install[@]}"
        else
            log "所有基础组件已安装"
        fi
    else
        warn "未检测到支持的 Linux 发行版 (Debian/Ubuntu/CentOS/RHEL)"
        log "请手动安装依赖: ${packages[*]}"
    fi
}


validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]
}


validate_backend() {
    local backend="$1"
    local ip octet
    local valid=true
    local -a octets

    if [[ "$backend" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]{1,5})?/?$ ]]; then
        return 0
    fi

    if [[ "$backend" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]]; then
        ip="${backend%:*}"
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if (( 10#$octet > 255 )); then
                valid=false
                break
            fi
        done
        $valid && return 0
    fi

    [[ "$backend" =~ ^[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]]
}


validate_upstream_url() {
    local upstream="$1"
    [[ "$upstream" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]{1,5})?/?$ ]]
}


extract_url_host() {
    local url="$1"
    local authority
    authority="${url#*://}"
    authority="${authority%%/*}"
    printf '%s\n' "${authority%%:*}"
}


trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}


normalize_stream_upstream_list() {
    local input="$1"
    local item normalized host existing_host
    local -a raw_items=() normalized_items=() seen_hosts=()

    IFS=',' read -r -a raw_items <<< "$input"
    (( ${#raw_items[@]} > 0 && ${#raw_items[@]} <= 8 )) || return 1

    for item in "${raw_items[@]}"; do
        normalized="$(trim_whitespace "$item")"
        normalized="${normalized%/}"
        validate_upstream_url "$normalized" || return 1
        host="$(extract_url_host "$normalized")"
        host="${host,,}"
        for existing_host in "${seen_hosts[@]}"; do
            [[ "$existing_host" != "$host" ]] || return 1
        done
        seen_hosts+=("$host")
        normalized_items+=("$normalized")
    done

    (IFS=','; printf '%s\n' "${normalized_items[*]}")
}


stream_route_prefix() {
    local base_prefix="$1"
    local index="$2"
    local host="$3"
    local label checksum

    if (( index == 0 )); then
        printf '%s\n' "$base_prefix"
        return 0
    fi
    label="$(printf '%s' "${host%%.*}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/_/g')"
    checksum="$(printf '%s' "$host" | sha256sum | awk '{print substr($1,1,8)}')"
    printf '%s_%s_%s\n' "$base_prefix" "$label" "$checksum"
}


make_site_id() {
    local front_domain="$1"
    local readable checksum
    readable="$(printf '%s' "${front_domain%%.*}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g')"
    checksum="$(printf '%s' "$front_domain" | sha256sum | awk '{print substr($1,1,12)}')"
    printf 'stream_%s_%s\n' "$readable" "$checksum"
}


default_stream_prefix() {
    local front_domain="$1"
    local label
    label="$(printf '%s' "${front_domain%%.*}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/_/g')"
    printf '__%s_stream\n' "$label"
}


valid_menu_choice() {
    [[ "$1" =~ ^(10|[0-9])$ ]]
}


ensure_caddy_dir() {
    mkdir -p "$(dirname -- "$CADDYFILE")"
}


new_candidate_file() {
    local candidate config_dir

    if ! ensure_caddy_dir; then
        error "无法创建 Caddy 配置目录：$(dirname -- "$CADDYFILE")"
        return 1
    fi
    config_dir="$(dirname -- "$CADDYFILE")"
    if ! candidate="$(mktemp "$config_dir/.Caddyfile.candidate.XXXXXX")"; then
        error "无法创建 Caddy 候选配置文件"
        return 1
    fi
    printf '%s\n' "$candidate"
}


backup_current_config() {
    local expected_sha="${1-}"
    local temporary_backup final_backup stamp unique_part
    local source_sha backup_sha transaction_sha
    LAST_BACKUP=""

    if [[ -L "$CADDYFILE" ]]; then
        error "Caddyfile 不是普通文件，拒绝自动覆盖"
        return 1
    fi
    if [[ ! -e "$CADDYFILE" ]]; then
        [[ -z "$expected_sha" ]] && return 0
        error "需要备份的 Caddyfile 已不存在，正式配置未修改"
        return 1
    fi
    if [[ ! -f "$CADDYFILE" ]]; then
        error "Caddyfile 不是普通文件，拒绝自动覆盖"
        return 1
    fi

    source_sha="$(config_sha256 "$CADDYFILE")" || {
        error "无法校验待备份的 Caddyfile"
        return 1
    }
    if [[ -n "$expected_sha" && "$source_sha" != "$expected_sha" ]]; then
        error "Caddyfile 在备份前发生变化，已拒绝继续"
        return 1
    fi
    transaction_sha="${expected_sha:-$source_sha}"

    if ! install -d -m 700 -- "$BACKUP_DIR"; then
        error "无法创建安全备份目录：$BACKUP_DIR"
        return 1
    fi

    if ! temporary_backup="$(mktemp "$BACKUP_DIR/.Caddyfile.backup.XXXXXX")"; then
        error "无法创建临时备份文件"
        return 1
    fi
    if ! cp -a -- "$CADDYFILE" "$temporary_backup" \
        || ! cmp -s -- "$CADDYFILE" "$temporary_backup"; then
        rm -f -- "$temporary_backup"
        error "Caddyfile 备份或备份校验失败，正式配置未修改"
        return 1
    fi
    backup_sha="$(config_sha256 "$temporary_backup")" || backup_sha=""
    if [[ "$backup_sha" != "$source_sha" ]]; then
        rm -f -- "$temporary_backup"
        error "Caddyfile 临时备份校验值不一致，正式配置未修改"
        return 1
    fi

    stamp="$(date +%Y%m%d-%H%M%S-%N)"
    unique_part="${temporary_backup##*.backup.}"
    final_backup="$BACKUP_DIR/Caddyfile.${stamp}.${unique_part}.bak"
    if ! mv -fT -- "$temporary_backup" "$final_backup" \
        || ! cmp -s -- "$CADDYFILE" "$final_backup"; then
        rm -f -- "$temporary_backup" "$final_backup"
        error "Caddyfile 最终备份校验失败，正式配置未修改"
        return 1
    fi
    backup_sha="$(config_sha256 "$final_backup")" || backup_sha=""
    source_sha="$(config_sha256 "$CADDYFILE")" || source_sha=""
    if [[ "$backup_sha" != "$transaction_sha" || "$source_sha" != "$transaction_sha" ]]; then
        rm -f -- "$final_backup"
        error "Caddyfile 最终备份与事务起始版本不一致，正式配置未修改"
        return 1
    fi

    LAST_BACKUP="$final_backup"
    return 0
}


prune_old_backups() {
    local list_file sorted_file backup_name
    local keep_limit=5 kept=0
    local cleanup_failed=false removed_any=false current_present=false
    local -a backups=()

    [[ -d "$BACKUP_DIR" ]] || return 0
    list_file="$(mktemp)" || {
        warn "无法创建备份清单，已保留全部备份文件"
        return 0
    }
    sorted_file="$(mktemp)" || {
        rm -f -- "$list_file"
        warn "无法创建备份排序清单，已保留全部备份文件"
        return 0
    }

    if ! find "$BACKUP_DIR" -maxdepth 1 -type f -name 'Caddyfile.*.bak' -printf '%f\n' > "$list_file" \
        || ! sort -r "$list_file" > "$sorted_file"; then
        rm -f -- "$list_file" "$sorted_file"
        warn "无法统计旧备份，已保留全部备份文件"
        return 0
    fi
    mapfile -t backups < "$sorted_file"
    rm -f -- "$list_file" "$sorted_file"

    for backup_name in "${backups[@]}"; do
        if [[ -n "$LAST_BACKUP" && "$backup_name" == "${LAST_BACKUP##*/}" ]]; then
            current_present=true
            break
        fi
    done
    if [[ "$current_present" == "true" ]]; then
        keep_limit=4
    fi

    for backup_name in "${backups[@]}"; do
        if [[ "$current_present" == "true" && "$backup_name" == "${LAST_BACKUP##*/}" ]]; then
            continue
        fi
        if (( kept < keep_limit )); then
            kept=$((kept + 1))
            continue
        fi
        if ! rm -f -- "$BACKUP_DIR/$backup_name"; then
            cleanup_failed=true
        else
            removed_any=true
        fi
    done

    if [[ "$cleanup_failed" == "true" ]]; then
        warn "部分旧备份清理失败，未影响本次配置写入"
    elif [[ "$removed_any" == "true" ]]; then
        log "已清理旧备份文件"
    fi
}


caddyfile_has_effective_content() {
    local file="$1"
    local status

    [[ -f "$file" && -r "$file" ]] || return 2
    if awk '
        {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            if (line != "" && line !~ /^#/) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$file"; then
        status=0
    else
        status=$?
    fi
    case "$status" in
        0|1) return "$status" ;;
        *)   return 2 ;;
    esac
}


adapt_caddyfile_to_json() {
    local file="$1"
    local output_file="$2"
    local content_status

    if caddyfile_has_effective_content "$file"; then
        caddy adapt --config "$file" --adapter caddyfile > "$output_file"
        return $?
    else
        content_status=$?
    fi
    if (( content_status == 1 )); then
        printf '{}\n' > "$output_file"
        return $?
    fi
    return 2
}


adapted_json_requires_caddy() {
    local json_file="$1"
    jq -e '((.apps? // {}) | length) > 0' "$json_file" >/dev/null
}


config_sha256() {
    local output
    output="$(sha256sum -- "$1")" || return 1
    printf '%s\n' "${output%% *}"
}


caddy_main_pid() {
    systemctl show -p MainPID --value caddy 2>/dev/null
}


caddy_active_state() {
    systemctl show -p ActiveState --value caddy 2>/dev/null
}


caddy_service_is_healthy() {
    local pid

    systemctl is-active --quiet caddy || return 1
    pid="$(caddy_main_pid)" || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]]
}


caddy_service_is_stopped() {
    local state

    state="$(systemctl show -p ActiveState --value caddy 2>/dev/null)" || return 1
    [[ "$state" == "inactive" || "$state" == "failed" ]]
}


apply_caddy_runtime_state() {
    local desired_has_sites="$1"
    local was_active="$2"
    local old_pid="$3"
    local new_pid

    if [[ "$desired_has_sites" == "true" ]]; then
        systemctl restart caddy || return 1
        caddy_service_is_healthy || return 1
        new_pid="$(caddy_main_pid)" || return 1
        if [[ "$was_active" == "true" && "$new_pid" == "$old_pid" ]]; then
            return 1
        fi
        return 0
    fi

    systemctl stop caddy || return 1
    caddy_service_is_stopped
}


restore_config_atomic() {
    local previous_exists="$1"
    local backup_file="$2"
    local rollback_file config_dir

    if [[ "$previous_exists" == "true" ]]; then
        [[ -f "$backup_file" ]] || return 1
        config_dir="$(dirname -- "$CADDYFILE")"
        rollback_file="$(mktemp "$config_dir/.Caddyfile.rollback.XXXXXX")" || return 1
        if ! cp -a -- "$backup_file" "$rollback_file" \
            || ! cmp -s -- "$backup_file" "$rollback_file"; then
            rm -f -- "$rollback_file"
            return 1
        fi
        if ! mv -fT -- "$rollback_file" "$CADDYFILE" \
            || ! cmp -s -- "$backup_file" "$CADDYFILE"; then
            rm -f -- "$rollback_file"
            return 1
        fi
        return 0
    fi

    rm -f -- "$CADDYFILE" || return 1
    [[ ! -e "$CADDYFILE" ]]
}


restore_caddy_service_state() {
    local was_active="$1"

    if [[ "$was_active" == "true" ]]; then
        systemctl restart caddy || return 1
        caddy_service_is_healthy
        return $?
    fi

    systemctl stop caddy || return 1
    caddy_service_is_stopped
}


rollback_applied_candidate() {
    local previous_exists="$1"
    local was_active="$2"
    local expected_candidate_sha="$3"
    local current_sha

    if [[ -L "$CADDYFILE" || ! -f "$CADDYFILE" ]]; then
        error "严重：准备回滚时 Caddyfile 已被外部改变；为避免覆盖新内容，未自动回滚。旧备份：${LAST_BACKUP:-无}"
        return 2
    fi
    current_sha="$(config_sha256 "$CADDYFILE")" || current_sha=""
    if [[ -z "$current_sha" || "$current_sha" != "$expected_candidate_sha" ]]; then
        error "严重：准备回滚时检测到 Caddyfile 已被其他进程修改；为避免覆盖外部修改，未自动回滚。旧备份：${LAST_BACKUP:-无}"
        return 2
    fi

    if ! restore_config_atomic "$previous_exists" "$LAST_BACKUP"; then
        error "严重：新配置应用失败，并且磁盘配置回滚失败；备份保留在：${LAST_BACKUP:-无}"
        return 2
    fi
    if ! restore_caddy_service_state "$was_active"; then
        error "严重：磁盘配置已恢复，但 Caddy 服务状态恢复失败；备份：${LAST_BACKUP:-无}"
        return 2
    fi

    error "新配置未生效；旧配置和原服务状态已成功恢复"
    return 1
}


apply_candidate() {
    local candidate="$1"
    local previous_exists=false
    local was_active=false
    local desired_should_run=false
    local adapted_json route_status
    local before_sha="" current_sha candidate_sha installed_sha
    local old_pid="" apply_status service_state
    local config_dir candidate_device config_device

    if [[ ! -f "$candidate" || -L "$candidate" ]]; then
        error "候选配置不是普通文件，已停止操作"
        rm -f -- "$candidate"
        return 1
    fi
    config_dir="$(dirname -- "$CADDYFILE")"
    candidate_device="$(stat -c %d -- "$candidate")" || candidate_device=""
    config_device="$(stat -c %d -- "$config_dir")" || config_device=""
    if [[ -z "$candidate_device" || "$candidate_device" != "$config_device" ]]; then
        error "候选配置与正式配置目录不在同一文件系统，拒绝非原子替换"
        rm -f -- "$candidate"
        return 1
    fi

    if caddyfile_has_effective_content "$candidate"; then
        if ! caddy fmt --overwrite "$candidate"; then
            error "Caddy 格式化失败，正式配置未修改"
            rm -f -- "$candidate"
            return 1
        fi

        if ! caddy validate --config "$candidate" --adapter caddyfile; then
            error "Caddy 配置验证失败，正式配置未修改"
            rm -f -- "$candidate"
            return 1
        fi
    fi

    adapted_json="$(mktemp)" || {
        error "无法创建 Caddy 解析结果临时文件"
        rm -f -- "$candidate"
        return 1
    }
    if ! adapt_caddyfile_to_json "$candidate" "$adapted_json"; then
        error "无法解析候选 Caddy 配置，正式配置未修改"
        rm -f -- "$candidate" "$adapted_json"
        return 1
    fi
    if adapted_json_requires_caddy "$adapted_json"; then
        desired_should_run=true
    else
        route_status=$?
        if (( route_status != 1 )); then
            error "无法检查候选配置是否仍需运行 Caddy，正式配置未修改"
            rm -f -- "$candidate" "$adapted_json"
            return 1
        fi
    fi
    rm -f -- "$adapted_json"

    candidate_sha="$(config_sha256 "$candidate")" || {
        error "无法计算候选配置校验值"
        rm -f -- "$candidate"
        return 1
    }

    if [[ -L "$CADDYFILE" ]]; then
        error "Caddyfile 是符号链接，拒绝自动覆盖"
        rm -f -- "$candidate"
        return 1
    fi
    if [[ -e "$CADDYFILE" ]]; then
        if [[ ! -f "$CADDYFILE" ]]; then
            error "Caddyfile 不是普通文件，拒绝自动覆盖"
            rm -f -- "$candidate"
            return 1
        fi
        previous_exists=true
        before_sha="$(config_sha256 "$CADDYFILE")" || {
            error "无法计算原 Caddyfile 校验值"
            rm -f -- "$candidate"
            return 1
        }
    fi

    service_state="$(caddy_active_state)" || {
        error "无法读取 Caddy 服务状态，已停止操作"
        rm -f -- "$candidate"
        return 1
    }
    case "$service_state" in
        active)
            was_active=true
            if [[ "$previous_exists" != "true" ]]; then
                error "Caddy 正在运行但 Caddyfile 不存在，无法保证安全回滚"
                rm -f -- "$candidate"
                return 1
            fi
            old_pid="$(caddy_main_pid)" || {
                error "无法读取 Caddy 主进程 PID，已停止操作"
                rm -f -- "$candidate"
                return 1
            }
            if [[ ! "$old_pid" =~ ^[1-9][0-9]*$ ]]; then
                error "Caddy 服务状态异常，已停止操作"
                rm -f -- "$candidate"
                return 1
            fi
            ;;
        inactive|failed)
            ;;
        *)
            error "Caddy 服务处于无法安全修改的状态：${service_state:-未知}"
            rm -f -- "$candidate"
            return 1
            ;;
    esac

    if ! backup_current_config "$before_sha"; then
        rm -f -- "$candidate"
        return 1
    fi

    if [[ "$previous_exists" == "true" ]]; then
        current_sha="$(config_sha256 "$CADDYFILE")" || {
            error "无法再次校验原 Caddyfile，已停止操作"
            rm -f -- "$candidate"
            return 1
        }
        if [[ "$current_sha" != "$before_sha" ]]; then
            error "检测到 Caddyfile 在操作期间被其他进程修改，已拒绝覆盖"
            rm -f -- "$candidate"
            return 1
        fi

        if ! chown --reference="$CADDYFILE" "$candidate" \
            || ! chmod --reference="$CADDYFILE" "$candidate"; then
            error "无法复制原 Caddyfile 的所有者或权限，正式配置未修改"
            rm -f -- "$candidate"
            return 1
        fi
        if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
            if ! chcon --reference="$CADDYFILE" "$candidate"; then
                error "无法复制 Caddyfile 的 SELinux 上下文，正式配置未修改"
                rm -f -- "$candidate"
                return 1
            fi
        fi
    else
        if [[ -e "$CADDYFILE" || -L "$CADDYFILE" ]]; then
            error "检测到 Caddyfile 在操作期间被创建，已拒绝覆盖"
            rm -f -- "$candidate"
            return 1
        fi
        if ! chmod 0644 "$candidate"; then
            error "无法设置候选配置权限，正式配置未修改"
            rm -f -- "$candidate"
            return 1
        fi
    fi

    if [[ "$previous_exists" == "true" ]]; then
        if ! mv -fT -- "$candidate" "$CADDYFILE"; then
            error "无法原子替换 Caddyfile，正式配置未修改"
            rm -f -- "$candidate"
            return 1
        fi
    else
        if ! mv -nT -- "$candidate" "$CADDYFILE" || [[ -e "$candidate" ]]; then
            error "Caddyfile 在安装时已存在，未覆盖新出现的配置"
            rm -f -- "$candidate"
            return 1
        fi
    fi

    installed_sha="$(config_sha256 "$CADDYFILE")" || installed_sha=""
    if [[ "$installed_sha" != "$candidate_sha" ]]; then
        error "正式配置写入校验失败，正在回滚"
        rollback_applied_candidate "$previous_exists" "$was_active" "$candidate_sha"
        return $?
    fi

    if apply_caddy_runtime_state "$desired_should_run" "$was_active" "$old_pid"; then
        apply_status=0
    else
        apply_status=$?
        error "Caddy 未能应用新配置（状态 $apply_status），正在回滚"
        rollback_applied_candidate "$previous_exists" "$was_active" "$candidate_sha"
        return $?
    fi

    prune_old_backups
    if [[ "$desired_should_run" == "true" ]]; then
        echo -e "\n${GREEN}=========================================="
        echo -e " 操作成功！Caddy 运行中。"
        echo -e "==========================================${PLAIN}"
    else
        warn "已删除最后一个站点，Caddyfile 已清空并停止 Caddy"
    fi
    return 0
}


check_managed_markers() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    awk '
        function fail() { bad=1 }
        $1 == "#" && $2 == "BEGIN" && ($3 == "CADDY_EMBY_STREAM" || $3 == "CADDY_EMBY_SITE") {
            type=$3
            key=$4
            if (open_type != "" || key == "" || seen[type SUBSEP key]++) fail()
            open_type=type
            open_key=key
            next
        }
        $1 == "#" && $2 == "END" && ($3 == "CADDY_EMBY_STREAM" || $3 == "CADDY_EMBY_SITE") {
            if (open_type == "" || $3 != open_type || $4 != open_key) fail()
            open_type=""
            open_key=""
            next
        }
        END {
            if (open_type != "") fail()
            exit bad ? 1 : 0
        }
    ' "$file"
}


remove_stream_group_file() {
    local source_file="$1"
    local output_file="$2"
    local front_domain="$3"

    awk -v begin="$STREAM_BEGIN $front_domain " -v end="$STREAM_END $front_domain" '
        index($0, begin) == 1 {
            if (skip || found) err=1
            skip=1
            found=1
            next
        }
        skip && $0 == end { skip=0; next }
        !skip { print }
        END {
            if (skip || !found || err) exit 42
        }
    ' "$source_file" > "$output_file"
}


remove_managed_site_file() {
    local source_file="$1"
    local output_file="$2"
    local domain="$3"

    awk -v begin="$SITE_BEGIN $domain" -v end="$SITE_END $domain" '
        $0 == begin {
            if (skip || found) err=1
            skip=1
            found=1
            next
        }
        skip && $0 == end { skip=0; next }
        !skip { print }
        END {
            if (skip || !found || err) exit 42
        }
    ' "$source_file" > "$output_file"
}


remove_site_block_file() {
    local source_file="$1"
    local output_file="$2"
    local domain="$3"

    awk -v target="$domain" '
        function opens(line, copy)  { copy=line; return gsub(/\{/, "", copy) }
        function closes(line, copy) { copy=line; return gsub(/\}/, "", copy) }
        BEGIN { skipping=0; depth=0; found=0; bad=0 }
        {
            if (!skipping && $0 == target " {") {
                if (found) bad=1
                found++
                skipping=1
                depth=opens($0)-closes($0)
                next
            }

            if (skipping) {
                depth += opens($0)-closes($0)
                if (depth <= 0) skipping=0
                next
            }

            print
        }
        END {
            if (skipping || found != 1 || bad) exit 42
        }
    ' "$source_file" > "$output_file"
}


stream_group_exists() {
    local front_domain="$1"
    [[ -f "$CADDYFILE" ]] && grep -Fqx "$STREAM_END $front_domain" "$CADDYFILE"
}


managed_site_exists() {
    local domain="$1"
    [[ -f "$CADDYFILE" ]] && grep -Fqx "$SITE_END $domain" "$CADDYFILE"
}


exact_site_block_exists_in_file() {
    local file="$1"
    local domain="$2"
    grep -Fqx "$domain {" "$file"
}


adapted_json_contains_domain() {
    local json_file="$1"
    local domain="$2"
    local target="${domain,,}"

    target="${target%.}"
    jq -e --arg target "$target" '
        [
            (.apps.http.servers? // {})[]?
            | ..
            | objects
            | select((.match? | type) == "array")
            | .match[]
            | objects
            | (.host? // [])
            | .[]
            | strings
            | ascii_downcase
        ]
        | any(
            . as $host
            | $host == $target
              or (($host | startswith("*.")) and ($target | endswith($host[1:])))
        )
    ' "$json_file" >/dev/null
}


domain_conflict_in_file() {
    local file="$1"
    local domain="$2"
    local adapted_json error_file status content_status

    if caddyfile_has_effective_content "$file"; then
        :
    else
        content_status=$?
        (( content_status == 1 )) && return 1
        return 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
        error "缺少 jq，无法可靠检查现有域名冲突"
        return 2
    fi

    adapted_json="$(mktemp)" || return 2
    error_file="$(mktemp)" || {
        rm -f -- "$adapted_json"
        return 2
    }

    if ! adapt_caddyfile_to_json "$file" "$adapted_json" 2> "$error_file"; then
        error "Caddy 无法解析现有配置，拒绝在无法确认域名归属时自动修改"
        sed -n '1,5p' "$error_file" >&2
        rm -f -- "$adapted_json" "$error_file"
        return 2
    fi

    if adapted_json_contains_domain "$adapted_json" "$domain"; then
        status=0
    else
        status=$?
    fi
    rm -f -- "$adapted_json" "$error_file"

    case "$status" in
        0|1) return "$status" ;;
        *)   return 2 ;;
    esac
}


ensure_domain_available_in_file() {
    local file="$1"
    local domain="$2"
    local label="$3"
    local status

    if domain_conflict_in_file "$file" "$domain"; then
        error "$label $domain 已被现有 Caddy 配置使用，未做任何修改"
        return 1
    else
        status=$?
    fi

    if (( status == 2 )); then
        error "无法可靠检查 $label $domain，已拒绝自动修改"
        return 1
    fi
    return 0
}


domain_in_stream_group() {
    local domain="$1"
    [[ -f "$CADDYFILE" ]] || return 1
    awk -v target="$domain" '
        $1 == "#" && $2 == "BEGIN" && $3 == "CADDY_EMBY_STREAM" {
            if ($4 == target || $5 == target) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$CADDYFILE"
}


build_standard_config_block() {
    local domain="$1"
    local backend="$2"

    cat <<EOF
$SITE_BEGIN $domain
$domain {
    encode gzip
    header Access-Control-Allow-Origin *

    reverse_proxy $backend {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up Host {upstream_hostport}
    }
}
$SITE_END $domain
EOF
}


build_stream_config_block() {
    local front_domain="$1"
    local route_domain="$2"
    local api_upstream="$3"
    local stream_upstream_list="$4"
    local stream_prefix="$5"
    local site_id="$6"
    local api_host stream_host route_prefix snippet_name
    local index target_index
    local -a stream_upstreams=() stream_hosts=() stream_regexes=()
    local -a route_prefixes=() snippet_names=()

    api_host="$(extract_url_host "$api_upstream")"
    IFS=',' read -r -a stream_upstreams <<< "$stream_upstream_list"
    for index in "${!stream_upstreams[@]}"; do
        stream_host="$(extract_url_host "${stream_upstreams[$index]}")"
        stream_hosts+=("$stream_host")
        stream_regexes+=("${stream_host//./[.]}")
        route_prefix="$(stream_route_prefix "$stream_prefix" "$index" "$stream_host")"
        route_prefixes+=("$route_prefix")
        if (( ${#stream_upstreams[@]} == 1 )); then
            snippet_names+=("${site_id}_stream")
        else
            snippet_names+=("${site_id}_stream_$((index + 1))")
        fi
    done

    printf '%s\n' "$STREAM_BEGIN $front_domain $route_domain"
    printf '(%s_api) {\n' "$site_id"
    printf '    reverse_proxy %s {\n' "$api_upstream"
    printf '        header_up Host %s\n' "$api_host"
    printf '        header_up -X-Forwarded-Host\n\n'
    for index in "${!stream_upstreams[@]}"; do
        printf '        header_down Location "(?i)^https?://%s(:[0-9]+)?/" "https://{http.request.host}/%s/"\n' \
            "${stream_regexes[$index]}" "${route_prefixes[$index]}"
    done
    printf '    }\n}\n'

    for index in "${!stream_upstreams[@]}"; do
        snippet_name="${snippet_names[$index]}"
        printf '\n(%s) {\n' "$snippet_name"
        printf '    reverse_proxy %s {\n' "${stream_upstreams[$index]}"
        printf '        header_up Host %s\n' "${stream_hosts[$index]}"
        printf '        header_up -X-Forwarded-Host\n\n'
        for target_index in "${!stream_upstreams[@]}"; do
            printf '        header_down Location "(?i)^https?://%s(:[0-9]+)?/" "https://{http.request.host}/%s/"\n' \
                "${stream_regexes[$target_index]}" "${route_prefixes[$target_index]}"
        done
        printf '    }\n}\n'
    done

    printf '\n%s {\n' "$route_domain"
    for index in "${!stream_upstreams[@]}"; do
        printf '    handle_path /%s/* {\n' "${route_prefixes[$index]}"
        printf '        import %s\n' "${snippet_names[$index]}"
        printf '    }\n\n'
    done
    printf '    handle {\n        import %s_api\n    }\n}\n' "$site_id"

    printf '\n%s {\n' "$front_domain"
    printf '    @route_root path /%s\n' "$route_domain"
    printf '    redir @route_root /%s/ 308\n\n' "$route_domain"
    printf '    handle_path /%s/* {\n' "$route_domain"
    printf '        import %s_api\n' "$site_id"
    printf '    }\n\n'
    for index in "${!stream_upstreams[@]}"; do
        printf '    handle_path /%s/* {\n' "${route_prefixes[$index]}"
        printf '        import %s\n' "${snippet_names[$index]}"
        printf '    }\n\n'
    done
    printf '    handle {\n        import %s_api\n    }\n}\n' "$site_id"
    printf '%s\n' "$STREAM_END $front_domain"
}


append_block_to_file() {
    local file="$1"
    local block="$2"

    if [[ -s "$file" ]]; then
        printf '\n' >> "$file" || return 1
    fi
    printf '%s\n' "$block" >> "$file"
}


copy_config_to_candidate() {
    local source_file="$1"
    local candidate="$2"

    if ! cp -- "$source_file" "$candidate" \
        || ! cmp -s -- "$source_file" "$candidate"; then
        error "复制现有 Caddyfile 到候选配置失败，正式配置未修改"
        return 1
    fi
}


check_port() {
    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}正在查询 80 和 443 端口占用情况...${PLAIN}"
    echo -e "------------------------------------------------"
    if command -v netstat &>/dev/null; then
        netstat -tunlp | grep -E ':80|:443' || true
    else
        ss -tulpn | grep -E ':80|:443' || true
    fi
    echo -e "------------------------------------------------"
    echo -e "如果显示 nginx/apache，请使用菜单 [9] 清理。"
    echo -e "如果显示 caddy，属正常现象。"
}


kill_port() {
    echo -e "${RED}正在强制停止常见 Web 服务并清理端口...${PLAIN}"
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true
    systemctl disable apache2 2>/dev/null || true
    systemctl stop httpd 2>/dev/null || true

    if command -v fuser &>/dev/null; then
        fuser -k 80/tcp 2>/dev/null || true
        fuser -k 443/tcp 2>/dev/null || true
    else
        killall -9 caddy 2>/dev/null || true
        killall -9 nginx 2>/dev/null || true
        killall -9 httpd 2>/dev/null || true
    fi
    log "清理完成！"
    sleep 1
}


install_caddy() {
    if command -v caddy &>/dev/null; then
        warn "Caddy 已安装。"
        return 0
    fi

    log "正在安装 Caddy..."
    install_base

    if [[ -f /etc/debian_version ]]; then
        apt install -y debian-keyring debian-archive-keyring apt-transport-https
        curl -1fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
        apt update
        apt install caddy -y
    elif [[ -f /etc/redhat-release ]]; then
        yum install yum-plugin-copr -y
        yum copr enable @caddyserver/caddy -y
        yum install caddy -y
    fi

    if command -v caddy &>/dev/null; then
        systemctl enable caddy
        log "Caddy 安装完成！"
    else
        error "Caddy 安装失败，请检查网络或手动安装"
        return 1
    fi
}


configure_caddy() {
    local mode="new"
    local config_mode domain backend config_block
    local candidate

    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}添加/覆盖普通反代配置（支持多站）${PLAIN}"
    echo -e "------------------------------------------------"

    if ! check_managed_markers "$CADDYFILE"; then
        error "Caddyfile 中的托管标记缺失、嵌套或重复，已拒绝自动修改"
        return 1
    fi

    if [[ -s "$CADDYFILE" ]]; then
        echo -e "检测到已有配置文件。"
        echo -e " ${GREEN}1.${PLAIN} 覆盖整个 Caddyfile（仅保留本次站点）"
        echo -e " ${GREEN}2.${PLAIN} 追加或替换同域名站点（保留其他站点）"
        read -r -p "请选择模式 [1-2]: " config_mode < /dev/tty
        if [[ "$config_mode" == "2" ]]; then
            mode="append"
        elif [[ "$config_mode" != "1" ]]; then
            warn "无效选择，将使用覆盖模式"
        fi
    fi

    read -r -p "请输入访问域名（例如 emby.example.com）: " domain < /dev/tty
    if ! validate_domain "$domain"; then
        error "域名格式无效"
        return 1
    fi
    domain="${domain,,}"

    read -r -p "请输入后端地址（例如 https://remote.example.com:443 或 127.0.0.1:8096）: " backend < /dev/tty
    [[ -z "$backend" ]] && backend="127.0.0.1:8096"
    backend="${backend%/}"
    if ! validate_backend "$backend"; then
        error "后端地址格式无效"
        return 1
    fi

    if [[ "$mode" == "append" ]] && domain_in_stream_group "$domain"; then
        error "域名 $domain 属于一个推流站点组，请先通过菜单 [4] 删除或使用菜单 [3] 更新"
        return 1
    fi

    echo -e "\n${SKYBLUE}配置摘要${PLAIN}"
    echo -e "访问域名 : https://$domain"
    echo -e "后端地址 : $backend"
    echo -e "写入方式 : $([[ "$mode" == "new" ]] && echo '覆盖整个 Caddyfile' || echo '追加/替换同域名')"
    read -r -p "确认写入？[y/N]: " confirm < /dev/tty
    [[ "$confirm" =~ ^[Yy]$ ]] || { warn "已取消"; return 0; }

    if ! candidate="$(new_candidate_file)"; then
        return 1
    fi
    if [[ "$mode" == "append" && -f "$CADDYFILE" ]]; then
        if managed_site_exists "$domain"; then
            remove_managed_site_file "$CADDYFILE" "$candidate" "$domain" || {
                error "旧配置标记不完整，已停止操作"
                rm -f -- "$candidate"
                return 1
            }
        elif exact_site_block_exists_in_file "$CADDYFILE" "$domain"; then
            remove_site_block_file "$CADDYFILE" "$candidate" "$domain" || {
                error "旧站点块结构异常，已停止操作"
                rm -f -- "$candidate"
                return 1
            }
        elif ! copy_config_to_candidate "$CADDYFILE" "$candidate"; then
            rm -f -- "$candidate"
            return 1
        fi
    elif ! : > "$candidate"; then
        error "无法初始化候选配置，正式配置未修改"
        rm -f -- "$candidate"
        return 1
    fi

    if ! ensure_domain_available_in_file "$candidate" "$domain" "访问域名"; then
        rm -f -- "$candidate"
        return 1
    fi

    config_block="$(build_standard_config_block "$domain" "$backend")"
    if ! append_block_to_file "$candidate" "$config_block"; then
        error "写入候选配置失败，正式配置未修改"
        rm -f -- "$candidate"
        return 1
    fi
    apply_candidate "$candidate"
}


commit_stream_proxy_config() {
    local front_domain="$1"
    local route_domain="$2"
    local api_upstream="$3"
    local stream_upstream_list="$4"
    local stream_prefix="$5"
    local site_id="$6"
    local candidate config_block

    if ! candidate="$(new_candidate_file)"; then
        return 1
    fi
    if [[ -f "$CADDYFILE" ]]; then
        if stream_group_exists "$front_domain"; then
            remove_stream_group_file "$CADDYFILE" "$candidate" "$front_domain" || {
                error "现有推流组标记不完整，已停止操作"
                rm -f -- "$candidate"
                return 1
            }
        elif ! copy_config_to_candidate "$CADDYFILE" "$candidate"; then
            rm -f -- "$candidate"
            return 1
        fi
    elif ! : > "$candidate"; then
        error "无法初始化候选配置，正式配置未修改"
        rm -f -- "$candidate"
        return 1
    fi

    if ! ensure_domain_available_in_file "$candidate" "$front_domain" "入口域名"; then
        rm -f -- "$candidate"
        return 1
    fi
    if ! ensure_domain_available_in_file "$candidate" "$route_domain" "兼容线路域名"; then
        rm -f -- "$candidate"
        return 1
    fi

    config_block="$(build_stream_config_block \
        "$front_domain" "$route_domain" "$api_upstream" "$stream_upstream_list" \
        "$stream_prefix" "$site_id")"
    if ! append_block_to_file "$candidate" "$config_block"; then
        error "写入候选推流配置失败，正式配置未修改"
        rm -f -- "$candidate"
        return 1
    fi

    apply_candidate "$candidate"
}


configure_stream_proxy() {
    local front_domain route_domain api_upstream stream_upstream_input stream_upstream_list
    local stream_prefix default_prefix site_id stream_host api_host upstream
    local confirm apply_status
    local index
    local -a stream_upstreams=() stream_hosts=()

    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}添加/覆盖 前后端反代推流配置（支持多站）${PLAIN}"
    echo -e "------------------------------------------------"

    if ! check_managed_markers "$CADDYFILE"; then
        error "Caddyfile 中的托管标记缺失、嵌套或重复，已拒绝自动修改"
        return 1
    fi

    read -r -p "1. 客户端入口域名（例如 dao.example.com）: " front_domain < /dev/tty
    if ! validate_domain "$front_domain"; then
        error "客户端入口域名格式无效"
        return 1
    fi
    front_domain="${front_domain,,}"

    read -r -p "2. 兼容线路域名（必填，用于兼容路径/备用直连，例如 db.example.com）: " route_domain < /dev/tty
    if [[ -z "$route_domain" ]]; then
        error "兼容线路域名为必填项"
        return 1
    fi
    if ! validate_domain "$route_domain"; then
        error "兼容线路域名格式无效"
        return 1
    fi
    route_domain="${route_domain,,}"

    if [[ "$front_domain" == "$route_domain" ]]; then
        error "客户端入口域名和兼容线路域名不能相同"
        return 1
    fi

    read -r -p "3. 登录/API 上游 URL（例如 https://api.example.com:443）: " api_upstream < /dev/tty
    api_upstream="${api_upstream%/}"
    if ! validate_upstream_url "$api_upstream"; then
        error "API 上游必须是 http:// 或 https:// 开头的域名 URL，且不能包含路径"
        return 1
    fi

    read -r -p "4. 实际 302 推流上游 URL（多个节点用逗号分隔，最多 8 个）: " stream_upstream_input < /dev/tty
    if ! stream_upstream_list="$(normalize_stream_upstream_list "$stream_upstream_input")"; then
        error "推流上游必须是 1-8 个 http:// 或 https:// 域名 URL，不能包含路径或重复主机"
        return 1
    fi
    IFS=',' read -r -a stream_upstreams <<< "$stream_upstream_list"

    default_prefix="$(default_stream_prefix "$front_domain")"
    read -r -p "5. 内部推流前缀（不含 /）[$default_prefix]: " stream_prefix < /dev/tty
    [[ -z "$stream_prefix" ]] && stream_prefix="$default_prefix"
    stream_prefix="${stream_prefix#/}"
    stream_prefix="${stream_prefix%/}"
    if [[ ! "$stream_prefix" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        error "内部推流前缀只能包含字母、数字、下划线和连字符"
        return 1
    fi

    api_host="$(extract_url_host "$api_upstream")"
    api_host="${api_host,,}"
    if [[ "$api_host" == "$front_domain" || "$api_host" == "$route_domain" ]]; then
        error "上游地址不能指向本配置的入口域名或兼容线路域名，否则会形成反代循环"
        return 1
    fi
    for upstream in "${stream_upstreams[@]}"; do
        stream_host="$(extract_url_host "$upstream")"
        stream_host="${stream_host,,}"
        if [[ "$stream_host" == "$front_domain" || "$stream_host" == "$route_domain" ]]; then
            error "上游地址不能指向本配置的入口域名或兼容线路域名，否则会形成反代循环"
            return 1
        fi
        stream_hosts+=("$stream_host")
    done
    site_id="$(make_site_id "$front_domain")"

    echo -e "\n${SKYBLUE}配置摘要${PLAIN}"
    echo -e "客户端入口 : https://$front_domain"
    echo -e "客户端端口 : 443"
    echo -e "客户端路径 : 留空（不要填写 /）"
    echo -e "兼容路径   : /$route_domain"
    echo -e "备用直连   : https://$route_domain"
    echo -e "API 上游   : $api_upstream"
    echo -e "推流节点数 : ${#stream_upstreams[@]}"
    for index in "${!stream_upstreams[@]}"; do
        echo -e "节点 $((index + 1))      : ${stream_upstreams[$index]}"
        echo -e "内部路径   : /$(stream_route_prefix "$stream_prefix" "$index" "${stream_hosts[$index]}")"
    done
    if stream_group_exists "$front_domain"; then
        echo -e "写入方式   : 替换相同入口域名的现有推流组"
    else
        echo -e "写入方式   : 追加新的推流组"
    fi
    read -r -p "6. 确认写入？[y/N]: " confirm < /dev/tty
    [[ "$confirm" =~ ^[Yy]$ ]] || { warn "已取消"; return 0; }

    if commit_stream_proxy_config \
        "$front_domain" "$route_domain" "$api_upstream" "$stream_upstream_list" \
        "$stream_prefix" "$site_id"; then
        echo -e "\n${GREEN}客户端/播放器填写：${PLAIN}"
        echo -e "地址：https://$front_domain"
        echo -e "端口：443"
        echo -e "路径：留空（不要填写 /）"
        echo -e "兼容路径：/$route_domain"
        echo -e "备用直连：https://$route_domain"
        echo -e "请确认入口域名和兼容线路域名均已解析到本 VPS。"
    else
        apply_status=$?
        return "$apply_status"
    fi
}


add_delete_entry() {
    local type="$1"
    local key="$2"
    local label="$3"
    local existing

    for existing in "${DELETE_KEYS[@]}"; do
        [[ "$existing" == "$key" ]] && return 0
    done
    DELETE_TYPES+=("$type")
    DELETE_KEYS+=("$key")
    DELETE_LABELS+=("$label")
    DELETE_ROUTES+=("${4:-}")
}


collect_delete_entries() {
    local front route domain
    DELETE_TYPES=()
    DELETE_KEYS=()
    DELETE_LABELS=()
    DELETE_ROUTES=()

    while IFS=$'\t' read -r front route; do
        [[ -n "$front" ]] || continue
        add_delete_entry "stream" "$front" "[推流] $front（路径留空；兼容线路：$route）" "$route"
    done < <(awk '
        $1 == "#" && $2 == "BEGIN" && $3 == "CADDY_EMBY_STREAM" {
            print $4 "\t" $5
        }
    ' "$CADDYFILE")

    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        add_delete_entry "managed" "$domain" "[普通] $domain" ""
    done < <(awk '
        $1 == "#" && $2 == "BEGIN" && $3 == "CADDY_EMBY_SITE" { print $4 }
    ' "$CADDYFILE")

    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        add_delete_entry "legacy" "$domain" "[普通/旧版] $domain" ""
    done < <(awk '
        /^# BEGIN CADDY_EMBY_/ { managed=1; next }
        /^# END CADDY_EMBY_/   { managed=0; next }
        !managed && /^[a-zA-Z0-9.-]+[[:space:]]*\{$/ {
            line=$0
            sub(/[[:space:]]*\{$/, "", line)
            print line
        }
    ' "$CADDYFILE")
}


delete_config() {
    local selection index selected_type selected_key confirm candidate
    local i route_match

    echo -e "------------------------------------------------"
    echo -e "${SKYBLUE}删除指定站点配置${PLAIN}"
    echo -e "------------------------------------------------"

    if [[ ! -s "$CADDYFILE" ]]; then
        error "未找到有效的 Caddyfile"
        return 1
    fi

    if ! check_managed_markers "$CADDYFILE"; then
        error "Caddyfile 中的托管标记缺失、嵌套或重复，已拒绝自动删除"
        return 1
    fi

    collect_delete_entries
    if (( ${#DELETE_KEYS[@]} == 0 )); then
        warn "没有找到可管理的站点"
        return 0
    fi

    echo -e "当前站点："
    for i in "${!DELETE_KEYS[@]}"; do
        echo -e " ${GREEN}$((i + 1)).${PLAIN} ${DELETE_LABELS[$i]}"
    done

    read -r -p "请输入编号或完整域名: " selection < /dev/tty
    [[ -n "$selection" ]] || return 0

    index=-1
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        if (( selection >= 1 && selection <= ${#DELETE_KEYS[@]} )); then
            index=$((selection - 1))
        fi
    else
        for i in "${!DELETE_KEYS[@]}"; do
            if [[ "${DELETE_KEYS[$i]}" == "$selection" ]]; then
                index="$i"
                break
            fi
            if [[ "${DELETE_TYPES[$i]}" == "stream" ]]; then
                route_match="${DELETE_ROUTES[$i]}"
                if [[ "$route_match" == "$selection" ]]; then
                    index="$i"
                    break
                fi
            fi
        done
    fi

    if (( index < 0 )); then
        error "无效的编号或域名"
        return 1
    fi

    selected_type="${DELETE_TYPES[$index]}"
    selected_key="${DELETE_KEYS[$index]}"
    echo -e "将删除：${DELETE_LABELS[$index]}"
    read -r -p "确定删除？[y/N]: " confirm < /dev/tty
    [[ "$confirm" =~ ^[Yy]$ ]] || { warn "已取消"; return 0; }

    if ! candidate="$(new_candidate_file)"; then
        return 1
    fi
    case "$selected_type" in
        stream)
            remove_stream_group_file "$CADDYFILE" "$candidate" "$selected_key" || {
                error "推流组标记不完整，未删除任何配置"
                rm -f -- "$candidate"
                return 1
            }
            ;;
        managed)
            remove_managed_site_file "$CADDYFILE" "$candidate" "$selected_key" || {
                error "普通站点标记不完整，未删除任何配置"
                rm -f -- "$candidate"
                return 1
            }
            ;;
        legacy)
            remove_site_block_file "$CADDYFILE" "$candidate" "$selected_key" || {
                error "旧版站点块结构异常，未删除任何配置"
                rm -f -- "$candidate"
                return 1
            }
            ;;
    esac

    apply_candidate "$candidate"
}


restart_caddy() {
    local was_active=false
    local old_pid="" new_pid service_state

    if [[ ! -s "$CADDYFILE" ]]; then
        error "Caddyfile 不存在或为空，请先添加配置"
        return 1
    fi

    if ! caddy validate --config "$CADDYFILE" --adapter caddyfile; then
        error "当前 Caddyfile 验证失败，未执行重启"
        return 1
    fi

    service_state="$(caddy_active_state)" || {
        error "无法读取 Caddy 服务状态，未执行重启"
        return 1
    }
    case "$service_state" in
        active)
            was_active=true
            old_pid="$(caddy_main_pid)" || old_pid=""
            if [[ ! "$old_pid" =~ ^[1-9][0-9]*$ ]]; then
                error "无法确认当前 Caddy 主进程，未执行重启"
                return 1
            fi
            ;;
        inactive|failed)
            ;;
        *)
            error "Caddy 服务处于无法安全重启的状态：${service_state:-未知}"
            return 1
            ;;
    esac

    log "正在重启 Caddy..."
    if ! systemctl restart caddy; then
        error "Caddy 重启命令失败，请查看：systemctl status caddy -l"
        return 1
    fi
    if ! caddy_service_is_healthy; then
        error "Caddy 启动失败，请查看：systemctl status caddy -l"
        return 1
    fi
    new_pid="$(caddy_main_pid)" || new_pid=""
    if [[ "$was_active" == "true" && "$new_pid" == "$old_pid" ]]; then
        error "Caddy 主进程未发生变化，不能确认重启成功"
        return 1
    fi
    log "Caddy 已正常运行"
}


uninstall_caddy() {
    local confirm
    echo -e "${RED}警告：将卸载 Caddy 并删除 $CADDY_DIR。${PLAIN}"
    read -r -p "确定继续？请输入 YES: " confirm < /dev/tty
    [[ "$confirm" == "YES" ]] || { warn "已取消卸载"; return 0; }

    systemctl stop caddy 2>/dev/null || true
    apt remove caddy -y 2>/dev/null || yum remove caddy -y 2>/dev/null || true
    rm -rf "$CADDY_DIR"
    log "Caddy 已卸载"
}


show_menu() {
    local num
    clear
    echo -e "############################################################"
    echo -e "#   Caddy + Emby 多站点及推流管理脚本 (V6 Pro)            #"
    echo -e "############################################################"
    echo -e " ${GREEN}1.${PLAIN} 安装环境 & Caddy"
    echo -e " ${GREEN}2.${PLAIN} 添加/覆盖 普通反代配置（支持多站）"
    echo -e " ${GREEN}3.${PLAIN} 添加/覆盖 前后端反代推流配置（支持多站）"
    echo -e " ${GREEN}4.${PLAIN} 删除指定站点配置"
    echo -e " ${GREEN}5.${PLAIN} 查看 Caddy 配置文件"
    echo -e "------------------------------------------------------------"
    echo -e " ${GREEN}6.${PLAIN} 停止 Caddy"
    echo -e " ${GREEN}7.${PLAIN} 重启 Caddy"
    echo -e " ${GREEN}8.${PLAIN} 查询 443/80 端口占用"
    echo -e " ${RED}9.${PLAIN} 强制处理端口占用（修复启动失败）"
    echo -e " ${RED}10.${PLAIN} 卸载 Caddy"
    echo -e "------------------------------------------------------------"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo -e ""
    read -r -p " 请输入数字 [0-10]: " num < /dev/tty

    if ! valid_menu_choice "$num"; then
        error "请输入有效的数字（0-10）"
        return 1
    fi

    case "$num" in
        1) install_base; install_caddy ;;
        2) install_base; install_caddy && configure_caddy ;;
        3) install_base; install_caddy && configure_stream_proxy ;;
        4) delete_config ;;
        5)
            if [[ -f "$CADDYFILE" ]]; then
                cat "$CADDYFILE"
            else
                warn "Caddyfile 不存在"
            fi
            ;;
        6)
            if systemctl is-active --quiet caddy; then
                systemctl stop caddy
                log "服务已停止"
            else
                warn "Caddy 服务未运行"
            fi
            ;;
        7) restart_caddy ;;
        8) install_base; check_port ;;
        9) install_base; kill_port ;;
        10) uninstall_caddy ;;
        0) exit 0 ;;
    esac
}


main() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！\n"
        exit 1
    fi

    mkdir -p /run/lock
    exec 9>/run/lock/caddy-emby-pro.lock
    if ! flock -n 9; then
        error "另一个 caddy-emby-pro 实例正在运行"
        exit 1
    fi

    register_shortcut || exit 1

    while true; do
        show_menu
        echo -e "\n${GREEN}按回车键返回主菜单...${PLAIN}"
        read -r _ < /dev/tty
    done
}


if [[ "${CADDY_EMBY_SOURCE_ONLY:-0}" != "1" ]]; then
    main "$@"
fi
