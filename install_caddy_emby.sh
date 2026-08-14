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

    local packages=("curl" "wget" "sudo" "socat" "net-tools" "psmisc" "sed" "grep" "gawk" "coreutils" "util-linux")
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
    mkdir -p "$CADDY_DIR"
}


new_candidate_file() {
    ensure_caddy_dir
    mktemp "$CADDY_DIR/.Caddyfile.candidate.XXXXXX"
}


backup_current_config() {
    local backup_count
    LAST_BACKUP=""

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    if [[ -f "$CADDYFILE" ]]; then
        LAST_BACKUP="$BACKUP_DIR/Caddyfile.$(date +%F_%H%M%S).bak"
        cp -a "$CADDYFILE" "$LAST_BACKUP"
    fi

    backup_count="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'Caddyfile.*.bak' 2>/dev/null | wc -l)"
    if (( backup_count > 5 )); then
        find "$BACKUP_DIR" -maxdepth 1 -type f -name 'Caddyfile.*.bak' -printf '%T@ %p\n' 2>/dev/null \
            | sort -nr \
            | tail -n +6 \
            | cut -d' ' -f2- \
            | xargs -r rm -f
        log "已清理旧备份文件"
    fi
}


has_site_blocks() {
    local file="$1"
    grep -Eq '^[a-zA-Z0-9.-]+([[:space:]]*,[[:space:]]*[a-zA-Z0-9.-]+)*[[:space:]]*\{' "$file"
}


apply_candidate() {
    local candidate="$1"
    local previous_exists=false

    if has_site_blocks "$candidate"; then
        if ! caddy fmt --overwrite "$candidate"; then
            error "Caddy 格式化失败，正式配置未修改"
            rm -f "$candidate"
            return 1
        fi

        if ! caddy validate --config "$candidate" --adapter caddyfile; then
            error "Caddy 配置验证失败，正式配置未修改"
            rm -f "$candidate"
            return 1
        fi
    fi

    [[ -f "$CADDYFILE" ]] && previous_exists=true
    backup_current_config
    if [[ -f "$CADDYFILE" ]]; then
        chown --reference="$CADDYFILE" "$candidate" 2>/dev/null || true
        chmod --reference="$CADDYFILE" "$candidate" 2>/dev/null || chmod 644 "$candidate"
    else
        chmod 644 "$candidate"
    fi
    mv -f "$candidate" "$CADDYFILE"

    if ! has_site_blocks "$CADDYFILE"; then
        systemctl stop caddy 2>/dev/null || true
        warn "已删除最后一个站点，Caddyfile 已清空并停止 Caddy"
        return 0
    fi

    log "正在重启 Caddy..."
    systemctl restart caddy
    sleep 2

    if systemctl is-active --quiet caddy; then
        echo -e "\n${GREEN}=========================================="
        echo -e " 操作成功！Caddy 运行中。"
        echo -e "==========================================${PLAIN}"
        return 0
    fi

    error "Caddy 启动失败，正在恢复修改前的配置"
    if [[ -n "$LAST_BACKUP" && -f "$LAST_BACKUP" ]]; then
        local rollback
        rollback="$(mktemp "$CADDY_DIR/.Caddyfile.rollback.XXXXXX")"
        cp -a "$LAST_BACKUP" "$rollback"
        mv -f "$rollback" "$CADDYFILE"
        systemctl restart caddy 2>/dev/null || true
    elif ! $previous_exists; then
        rm -f "$CADDYFILE"
        systemctl stop caddy 2>/dev/null || true
    fi
    error "已执行回滚，请查看：systemctl status caddy -l"
    return 1
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
        BEGIN { skipping=0; depth=0 }
        {
            if (!skipping && $0 == target " {") {
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
            if (skipping) exit 42
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


domain_block_exists_in_file() {
    local file="$1"
    local domain="$2"
    grep -Fqx "$domain {" "$file"
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
    local stream_upstream="$4"
    local stream_prefix="$5"
    local site_id="$6"
    local stream_host stream_regex

    stream_host="$(extract_url_host "$stream_upstream")"
    stream_regex="${stream_host//./[.]}"

    cat <<EOF
$STREAM_BEGIN $front_domain $route_domain
(${site_id}_api) {
    reverse_proxy $api_upstream {
        header_up Host {upstream_hostport}
        header_up -X-Forwarded-Host

        header_down Location "(?i)^https?://${stream_regex}(?::[0-9]+)?" "https://${front_domain}/${stream_prefix}"
    }
}

(${site_id}_stream) {
    reverse_proxy $stream_upstream {
        header_up Host {upstream_hostport}
        header_up -X-Forwarded-Host

        header_down Location "(?i)^https?://${stream_regex}(?::[0-9]+)?" "https://${front_domain}/${stream_prefix}"
    }
}

$route_domain {
    import ${site_id}_api
}

$front_domain {
    @route_root path /${route_domain}
    redir @route_root /${route_domain}/ 308

    handle_path /${route_domain}/* {
        import ${site_id}_api
    }

    handle_path /${stream_prefix}/* {
        import ${site_id}_stream
    }

    handle {
        import ${site_id}_api
    }
}
$STREAM_END $front_domain
EOF
}


append_block_to_file() {
    local file="$1"
    local block="$2"

    if [[ -s "$file" ]]; then
        printf '\n' >> "$file"
    fi
    printf '%s\n' "$block" >> "$file"
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

    candidate="$(new_candidate_file)"
    if [[ "$mode" == "append" && -f "$CADDYFILE" ]]; then
        if managed_site_exists "$domain"; then
            remove_managed_site_file "$CADDYFILE" "$candidate" "$domain" || {
                error "旧配置标记不完整，已停止操作"
                rm -f "$candidate"
                return 1
            }
        elif domain_block_exists_in_file "$CADDYFILE" "$domain"; then
            remove_site_block_file "$CADDYFILE" "$candidate" "$domain" || {
                error "旧站点块结构异常，已停止操作"
                rm -f "$candidate"
                return 1
            }
        else
            cp "$CADDYFILE" "$candidate"
        fi
    else
        : > "$candidate"
    fi

    config_block="$(build_standard_config_block "$domain" "$backend")"
    append_block_to_file "$candidate" "$config_block"
    apply_candidate "$candidate"
}


configure_stream_proxy() {
    local front_domain route_domain api_upstream stream_upstream
    local stream_prefix default_prefix site_id stream_host api_host config_block
    local candidate confirm

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

    read -r -p "2. 线路域名 / Hills 路径（例如 db.example.com）: " route_domain < /dev/tty
    if ! validate_domain "$route_domain"; then
        error "线路域名格式无效"
        return 1
    fi

    if [[ "$front_domain" == "$route_domain" ]]; then
        error "客户端入口域名和线路域名不能相同"
        return 1
    fi

    read -r -p "3. 登录/API 上游 URL（例如 https://api.example.com:443）: " api_upstream < /dev/tty
    api_upstream="${api_upstream%/}"
    if ! validate_upstream_url "$api_upstream"; then
        error "API 上游必须是 http:// 或 https:// 开头的域名 URL，且不能包含路径"
        return 1
    fi

    read -r -p "4. 实际 302 推流上游 URL（例如 https://stream.example.com:443）: " stream_upstream < /dev/tty
    stream_upstream="${stream_upstream%/}"
    if ! validate_upstream_url "$stream_upstream"; then
        error "推流上游必须是 http:// 或 https:// 开头的域名 URL，且不能包含路径"
        return 1
    fi

    default_prefix="$(default_stream_prefix "$front_domain")"
    read -r -p "5. 内部推流前缀（不含 /）[$default_prefix]: " stream_prefix < /dev/tty
    [[ -z "$stream_prefix" ]] && stream_prefix="$default_prefix"
    stream_prefix="${stream_prefix#/}"
    stream_prefix="${stream_prefix%/}"
    if [[ ! "$stream_prefix" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        error "内部推流前缀只能包含字母、数字、下划线和连字符"
        return 1
    fi

    stream_host="$(extract_url_host "$stream_upstream")"
    api_host="$(extract_url_host "$api_upstream")"
    if [[ "$api_host" == "$front_domain" || "$api_host" == "$route_domain" \
        || "$stream_host" == "$front_domain" || "$stream_host" == "$route_domain" ]]; then
        error "上游地址不能指向本配置的公网入口域名，否则会形成反代循环"
        return 1
    fi
    site_id="$(make_site_id "$front_domain")"

    echo -e "\n${SKYBLUE}配置摘要${PLAIN}"
    echo -e "客户端入口 : https://$front_domain"
    echo -e "Hills 端口 : 443"
    echo -e "Hills 路径 : /$route_domain"
    echo -e "API 上游   : $api_upstream"
    echo -e "实际流节点 : $stream_host"
    echo -e "推流上游   : $stream_upstream"
    echo -e "内部前缀   : /$stream_prefix"
    if stream_group_exists "$front_domain"; then
        echo -e "写入方式   : 替换相同入口域名的现有推流组"
    else
        echo -e "写入方式   : 追加新的推流组"
    fi
    read -r -p "6. 确认写入？[y/N]: " confirm < /dev/tty
    [[ "$confirm" =~ ^[Yy]$ ]] || { warn "已取消"; return 0; }

    candidate="$(new_candidate_file)"
    if [[ -f "$CADDYFILE" ]]; then
        if stream_group_exists "$front_domain"; then
            remove_stream_group_file "$CADDYFILE" "$candidate" "$front_domain" || {
                error "现有推流组标记不完整，已停止操作"
                rm -f "$candidate"
                return 1
            }
        else
            cp "$CADDYFILE" "$candidate"
        fi
    else
        : > "$candidate"
    fi

    if domain_block_exists_in_file "$candidate" "$front_domain"; then
        error "入口域名 $front_domain 已被其他配置使用，未做任何修改"
        rm -f "$candidate"
        return 1
    fi
    if domain_block_exists_in_file "$candidate" "$route_domain"; then
        error "线路域名 $route_domain 已被其他配置使用，未做任何修改"
        rm -f "$candidate"
        return 1
    fi

    config_block="$(build_stream_config_block \
        "$front_domain" "$route_domain" "$api_upstream" "$stream_upstream" \
        "$stream_prefix" "$site_id")"
    append_block_to_file "$candidate" "$config_block"

    if apply_candidate "$candidate"; then
        echo -e "\n${GREEN}Hills 填写：${PLAIN}"
        echo -e "地址：https://$front_domain"
        echo -e "端口：443"
        echo -e "路径：/$route_domain"
        echo -e "请确认两个公网域名均已解析到本 VPS。"
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
        add_delete_entry "stream" "$front" "[推流] $front（线路：$route）" "$route"
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

    candidate="$(new_candidate_file)"
    case "$selected_type" in
        stream)
            remove_stream_group_file "$CADDYFILE" "$candidate" "$selected_key" || {
                error "推流组标记不完整，未删除任何配置"
                rm -f "$candidate"
                return 1
            }
            ;;
        managed)
            remove_managed_site_file "$CADDYFILE" "$candidate" "$selected_key" || {
                error "普通站点标记不完整，未删除任何配置"
                rm -f "$candidate"
                return 1
            }
            ;;
        legacy)
            remove_site_block_file "$CADDYFILE" "$candidate" "$selected_key" || {
                error "旧版站点块结构异常，未删除任何配置"
                rm -f "$candidate"
                return 1
            }
            ;;
    esac

    apply_candidate "$candidate"
}


restart_caddy() {
    if [[ ! -s "$CADDYFILE" ]]; then
        error "Caddyfile 不存在或为空，请先添加配置"
        return 1
    fi

    if ! caddy validate --config "$CADDYFILE" --adapter caddyfile; then
        error "当前 Caddyfile 验证失败，未执行重启"
        return 1
    fi

    log "正在重启 Caddy..."
    systemctl restart caddy
    sleep 2
    if systemctl is-active --quiet caddy; then
        log "Caddy 已正常运行"
    else
        error "Caddy 启动失败，请查看：systemctl status caddy -l"
        return 1
    fi
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
