#!/usr/bin/env bash
# 中文管理入口；实际签发与续期由官方 acme.sh 完成。
# RUN_TMP belongs to with_lock's subshell and is consumed by its callback there.
# shellcheck disable=SC2034,SC2030,SC2031

ACME_HOME=/root/.acme.sh
CERT_DIR=/root/cert
STATE_DIR=/var/lib/acme-manager
LOCK_FILE=/run/lock/acme-manager.lock
RENEW_SCRIPT=/usr/local/libexec/acme-manager-renew
RENEW_LOG=/var/log/acme-manager.log
SYSTEM_CRONTAB=/etc/crontab
OS_RELEASE=/etc/os-release
RUN_TMP=

info() { printf '%s\n' "$*"; }
error() { printf '错误: %s\n' "$*" >&2; return 1; }
have() { command -v "$1" >/dev/null 2>&1; }
installed() { [[ -x "$ACME_HOME/acme.sh" ]]; }
acme() { "$ACME_HOME/acme.sh" --home "$ACME_HOME" "$@" 9>&-; }

detect_system() {
    local ID='' ID_LIKE=''
    [[ -r "$OS_RELEASE" ]] || { error "无法读取系统信息"; return 1; }
    # shellcheck source=/dev/null
    . "$OS_RELEASE"
    case "$ID" in
        alpine) SYSTEM=alpine; CRON_SERVICE=crond ;;
        debian|ubuntu) SYSTEM=debian; CRON_SERVICE=cron ;;
        centos|rhel|rocky|almalinux|ol|amzn|fedora) SYSTEM=rhel; CRON_SERVICE=crond ;;
        *)
            case " $ID_LIKE " in
                *" debian "*) SYSTEM=debian; CRON_SERVICE=cron ;;
                *" rhel "*|*" fedora "*) SYSTEM=rhel; CRON_SERVICE=crond ;;
                *) error "不支持的系统: $ID"; return 1 ;;
            esac ;;
    esac
}

install_packages() {
    case "$SYSTEM" in
        alpine) apk add --no-cache "$@" 9>&- ;;
        debian)
            apt-get update 9>&- &&
                DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" 9>&- ;;
        rhel)
            if have dnf; then dnf install -y "$@" 9>&-
            else yum install -y "$@" 9>&-; fi ;;
        *) error "系统尚未识别"; return 1 ;;
    esac
}

ensure_lock_tool() {
    have flock && return 0
    if [[ "$SYSTEM" == alpine ]]; then install_packages flock
    else install_packages util-linux; fi
}

install_dependencies() {
    local curl_package=curl
    if [[ "$SYSTEM" == rhel ]] && have rpm && rpm -q curl-minimal >/dev/null 2>&1; then
        curl_package=curl-minimal
    fi
    local -a packages=("$curl_package" ca-certificates openssl socat tar jq)
    case "$SYSTEM" in
        alpine) packages+=(bash flock openrc busybox-openrc) ;;
        debian) packages+=(util-linux cron iproute2 diffutils) ;;
        rhel) packages+=(util-linux cronie iproute diffutils) ;;
    esac
    install_packages "${packages[@]}" || return 1
    local cmd
    for cmd in curl openssl socat tar jq flock crontab cmp; do
        have "$cmd" || { error "缺少依赖: $cmd"; return 1; }
    done
}

start_cron() {
    if have rc-service && [[ -d /run/openrc ]]; then
        rc-update add "$CRON_SERVICE" default 9>&- &&
            rc-service "$CRON_SERVICE" start 9>&-
    elif have systemctl && [[ -d /run/systemd/system ]]; then
        systemctl enable --now "$CRON_SERVICE" 9>&-
    else
        error "未检测到运行中的 systemd / OpenRC，无法启用自动续期"
        return 1
    fi
}

with_lock() (
    local RUN_TMP
    umask 077
    unset HTTPS_INSECURE
    mkdir -p "$(dirname "$LOCK_FILE")" || exit 1
    exec 9>"$LOCK_FILE" || exit 1
    flock -n 9 || { error "已有证书管理或续期操作正在运行"; exit 1; }
    RUN_TMP=$(mktemp -d) || exit 1
    trap 'rm -rf -- "$RUN_TMP"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$@"
)

download() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 180 --retry 2 --output "$2" "$1" 9>&-
}

valid_domain() {
    local domain=$1 label
    [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != *..* ]] || return 1
    [[ "$domain" =~ ^[a-z0-9.-]+$ && ! "$domain" =~ ^[0-9.]+$ ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || return 1
    done
    [[ "$domain" != *. ]]
}

read_domain() {
    local input
    read -r -p "请输入域名（泛域名请输入 example.com）: " input || return 1
    domain=${input,,}
    domain=${domain%.}
    valid_domain "$domain" || { error "请输入有效域名；国际化域名请使用 Punycode"; return 1; }
}

read_email() {
    read -r -p "注册邮箱（留空跳过）: " email || return 1
    [[ -z "$email" || "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
        { error "邮箱格式不正确"; return 1; }
}

ensure_private_dirs() {
    [[ ! -L "$ACME_HOME" && ! -L "$CERT_DIR" && ! -L "$STATE_DIR" ]] ||
        { error "证书或状态目录不能是符号链接"; return 1; }
    mkdir -p "$ACME_HOME" "$CERT_DIR" "$STATE_DIR" || return 1
    chmod 700 "$ACME_HOME" "$CERT_DIR" "$STATE_DIR"
}

restore_tls_verification() {
    local conf="$ACME_HOME/account.conf" backup tmp
    [[ -f "$conf" ]] || return 0
    [[ ! -L "$conf" ]] || { error "account.conf 不能是符号链接"; return 1; }
    if ! grep -q '^HTTPS_INSECURE=' "$conf"; then return 0; fi
    backup="$STATE_DIR/account-$(date -u +%Y%m%dT%H%M%SZ)-$$.conf"
    cp -p "$conf" "$backup" && chmod 600 "$backup" || return 1
    tmp=$(mktemp "$ACME_HOME/account.conf.tmp.XXXXXX") || return 1
    if sed '/^HTTPS_INSECURE=/d' "$conf" > "$tmp" &&
        chmod 600 "$tmp" && mv -f "$tmp" "$conf"; then
        info "已移除旧版保存的跳过 HTTPS 校验设置；原配置已备份。"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

install_client() {
    local version source_dir
    if installed; then
        info "检测到现有 acme.sh，保留账户、证书及客户端版本。"
        return 0
    fi
    download https://api.github.com/repos/acmesh-official/acme.sh/releases/latest "$RUN_TMP/release.json" ||
        { error "读取官方发行版失败"; return 1; }
    version=$(jq -er '.tag_name | select(test("^v?[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$RUN_TMP/release.json") ||
        { error "官方发行版信息无效"; return 1; }
    download "https://github.com/acmesh-official/acme.sh/archive/refs/tags/$version.tar.gz" "$RUN_TMP/acme.tar.gz" ||
        { error "下载官方 acme.sh 失败"; return 1; }
    tar -tzf "$RUN_TMP/acme.tar.gz" > "$RUN_TMP/archive.list" || return 1
    # Only regular release paths under one top-level directory are accepted.
    awk '
        /^\// || /(^|\/)\.\.(\/|$)/ { exit 1 }
        { split($0, a, "/"); if (!root) root=a[1]; if (a[1]!=root) exit 1; n++ }
        END { if (!n) exit 1 }
    ' "$RUN_TMP/archive.list" || { error "发行包路径无效"; return 1; }
    tar -tvzf "$RUN_TMP/acme.tar.gz" > "$RUN_TMP/archive.verbose" || return 1
    awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" { exit 1 }' "$RUN_TMP/archive.verbose" ||
        { error "发行包包含链接或特殊文件"; return 1; }
    source_dir="$RUN_TMP/source"
    mkdir -p "$source_dir" || return 1
    tar -xzf "$RUN_TMP/acme.tar.gz" -C "$source_dir" --strip-components=1 --no-same-owner || return 1
    [[ -s "$source_dir/acme.sh" && -s "$source_dir/dnsapi/dns_cf.sh" ]] ||
        { error "发行包内容不完整"; return 1; }
    bash -n "$source_dir/acme.sh" || return 1
    local -a args=(--install --home "$ACME_HOME" --nocron --noprofile)
    [[ -z "$email" ]] || args+=(--accountemail "$email")
    (cd "$source_dir" && bash ./acme.sh "${args[@]}" 9>&-) || return 1
    installed || { error "acme.sh 安装未完成"; return 1; }
    acme --set-default-ca --server letsencrypt || return 1
}

# Remove only this wrapper's line and known legacy commands for this exact home.
# Custom hooks, other ACME homes, comments and unrelated --cron jobs are preserved.
filter_cron() {
    local input=$1 system=$2
    awk -v bin="$ACME_HOME/acme.sh" -v home="$ACME_HOME" -v runner="$RENEW_SCRIPT" -v is_system="$system" '
        /^[[:space:]]*#/ || NF<6 { print; next }
        {
            original=$0
            if (is_system && $6!="root") { print; next }
            first=is_system ? 7 : 6
            cmd=""
            for (i=first;i<=NF;i++) cmd=cmd (i==first ? "" : " ") $i
            if (cmd==runner " # passeway-acme-renew") next
            gsub(/"/, "", cmd)
            sub(/^(bash|sh) /, "", cmd)
            if (cmd==bin " --cron -f >/dev/null 2>&1" ||
                cmd==bin " --cron --home " home " > /dev/null" ||
                cmd==bin " --cron --home " home " > /dev/null 2>&1") next
            print original
        }
    ' "$input"
}

read_root_cron() {
    if LC_ALL=C crontab -l > "$1" 2> "$RUN_TMP/cron.err"; then return 0; fi
    if grep -Eq "no crontab for|can't open 'root': No such file or directory" "$RUN_TMP/cron.err"; then
        : > "$1"
        return 0
    fi
    cat "$RUN_TMP/cron.err" >&2
    error "无法读取 root 定时任务，已中止以防覆盖现有任务"
}

write_renew_script() {
    local staged="$RUN_TMP/renew"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'ACME_HOME=%q\nLOCK_FILE=%q\nLOG=%q\n' "$ACME_HOME" "$LOCK_FILE" "$RENEW_LOG"
        cat <<'RENEW'
umask 077
unset HTTPS_INSECURE
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p "$(dirname "$LOCK_FILE")" || exit 1
exec 9>"$LOCK_FILE" || exit 1
flock -n 9 || exit 0
[[ -x "$ACME_HOME/acme.sh" ]] || exit 1
if [[ -f "$LOG" ]] && [[ $(wc -c < "$LOG") -gt 1048576 ]]; then
    mv -f "$LOG" "$LOG.1" || exit 1
fi
touch "$LOG" && chmod 600 "$LOG" || exit 1
"$ACME_HOME/acme.sh" --cron --home "$ACME_HOME" >> "$LOG" 2>&1 9>&-
result=$?
if [[ $result -ne 0 ]]; then
    printf '%s 续期失败，退出码 %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$result" >> "$LOG"
fi
exit "$result"
RENEW
    } > "$staged" || return 1
    bash -n "$staged" || return 1
    mkdir -p "$(dirname "$RENEW_SCRIPT")" || return 1
    local tmp
    tmp=$(mktemp "$RENEW_SCRIPT.tmp.XXXXXX") || return 1
    if cat "$staged" > "$tmp" && chmod 700 "$tmp" && mv -f "$tmp" "$RENEW_SCRIPT"; then return 0; fi
    rm -f "$tmp"
    return 1
}

configure_schedule() {
    local mode=${1:-install} backup file tmp='' root_changed=0 system_changed=0
    have cmp || { error "缺少 cmp，请使用菜单 1 修复依赖"; return 1; }
    read_root_cron "$RUN_TMP/root.cron" || return 1
    filter_cron "$RUN_TMP/root.cron" 0 > "$RUN_TMP/root.new" || return 1
    if [[ -f "$SYSTEM_CRONTAB" ]]; then
        [[ ! -L "$SYSTEM_CRONTAB" ]] || { error "系统 crontab 是符号链接，请手动迁移"; return 1; }
        filter_cron "$SYSTEM_CRONTAB" 1 > "$RUN_TMP/system.new" || return 1
    fi
    # A custom scheduler must be reviewed before replacing it or removing its client.
    for file in "$RUN_TMP/root.new" "$RUN_TMP/system.new"; do
        [[ -f "$file" ]] || continue
        if grep -v '^[[:space:]]*#' "$file" | grep -F "$ACME_HOME" | grep -q -- '--cron'; then
            error "检测到此 ACME 目录的自定义续期任务，请先确认其钩子与调度方式"
            return 1
        fi
    done
    if [[ "$mode" == install ]]; then
        write_renew_script || return 1
        start_cron || return 1
        printf '17 3 * * * %s # passeway-acme-renew\n' "$RENEW_SCRIPT" >> "$RUN_TMP/root.new"
    fi
    # Prepare both snapshots and the system replacement before changing either table.
    backup="$STATE_DIR/cron-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    cmp -s "$RUN_TMP/root.cron" "$RUN_TMP/root.new" || root_changed=1
    if [[ -f "$SYSTEM_CRONTAB" ]] && ! cmp -s "$SYSTEM_CRONTAB" "$RUN_TMP/system.new"; then
        system_changed=1
    fi
    if [[ "$root_changed" == 1 || "$system_changed" == 1 ]]; then
        mkdir -p "$backup" && chmod 700 "$backup" || return 1
    fi
    if [[ "$root_changed" == 1 ]]; then
        cp "$RUN_TMP/root.cron" "$backup/root.crontab" || return 1
    fi
    if [[ "$system_changed" == 1 ]]; then
        cp -p "$SYSTEM_CRONTAB" "$backup/system.crontab" || return 1
        tmp=$(mktemp "$SYSTEM_CRONTAB.tmp.XXXXXX") || return 1
        if ! { cp -p "$SYSTEM_CRONTAB" "$tmp" && cat "$RUN_TMP/system.new" > "$tmp"; }; then
            rm -f "$tmp"
            error "准备系统定时任务失败，现有任务未修改"
            return 1
        fi
    fi
    if [[ "$root_changed" == 1 ]]; then
        if ! crontab "$RUN_TMP/root.new"; then
            [[ -z "$tmp" ]] || rm -f "$tmp"
            error "写入续期任务失败"
            return 1
        fi
    fi
    if [[ "$system_changed" == 1 ]]; then
        if ! mv -f "$tmp" "$SYSTEM_CRONTAB"; then
            rm -f "$tmp"
            if [[ "$root_changed" == 1 ]]; then
                crontab "$RUN_TMP/root.cron" || error "恢复 root crontab 失败，备份在 $backup"
            fi
            error "迁移旧定时任务失败，原系统 crontab 已保留"
            return 1
        fi
    fi
    if [[ "$mode" == remove ]]; then rm -f "$RENEW_SCRIPT" || return 1; fi
}

install_manager() {
    install_dependencies || return 1
    ensure_private_dirs || return 1
    restore_tls_verification || return 1
    local email=
    if ! installed; then read_email || return 1; fi
    install_client || return 1
    configure_schedule || return 1
    info "安装 / 续期修复完成。每天 03:17（服务器时间）检查证书，仅在需要时续期。"
}

require_ready() {
    installed || { error "请先使用菜单 1 安装 acme.sh"; return 1; }
    ensure_private_dirs || return 1
    restore_tls_verification || return 1
    local cmd
    for cmd in openssl socat crontab cmp; do
        have "$cmd" || { error "缺少 $cmd，请使用菜单 1 修复依赖"; return 1; }
    done
    configure_schedule
}

check_http_port() {
    local listeners
    if have ss; then listeners=$(ss -H -ltn) || return 1
    elif have netstat; then listeners=$(netstat -ltn) || return 1
    else error "缺少端口检查工具，请使用菜单 1 修复依赖"; return 1; fi
    if awk '$1=="LISTEN" { print $4 } $1 ~ /^tcp/ { print $4 }' <<< "$listeners" | grep -Eq ':80$'; then
        error "TCP 80 已被占用。请使用 Cloudflare DNS 验证，或自行安排停服后重试。"
        return 1
    fi
}

read_reload() {
    local conf="$ACME_HOME/${1}_ecc/$1.conf" value=
    if [[ -f "$conf" ]]; then
        value=$(sed -n "s/^Le_ReloadCmd='\(.*\)'$/\1/p" "$conf") || return 1
        if [[ "$value" == __ACME_BASE64__START_*__ACME_BASE64__END_ ]]; then
            value=${value#__ACME_BASE64__START_}
            value=${value%__ACME_BASE64__END_}
            value=$(printf '%s' "$value" | openssl base64 -d -A) || return 1
        fi
    fi
    reload_cmd=$value
    if [[ -n "$value" ]]; then info "已有重载命令: $value"; fi
    info "重载示例: systemctl reload nginx / rc-service nginx reload"
    local input
    read -r -p "重载命令（留空保留已有设置；输入 none 仅更新文件）: " input || return 1
    case "$input" in
        none) reload_cmd= ;;
        "") ;;
        *) reload_cmd=$input ;;
    esac
    if [[ -z "$reload_cmd" ]]; then info "本证书续期后仅更新文件；使用它的服务需另行配置重载。"; fi
}

validate_pair() {
    local cert=$1 key=$2 domain=$3 wildcard=${4:-0} cert_pub key_pub sans
    [[ -s "$cert" && -s "$key" ]] || { error "缺少证书或私钥"; return 1; }
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 ||
        { error "证书无效或已过期"; return 1; }
    cert_pub=$(openssl x509 -in "$cert" -pubkey -noout) || return 1
    key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null) || return 1
    [[ "$cert_pub" == "$key_pub" ]] || { error "证书与私钥不匹配"; return 1; }
    sans=$(openssl x509 -in "$cert" -noout -ext subjectAltName) || return 1
    sans=$(printf '%s\n' "$sans" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') || return 1
    grep -Fxq "DNS:$domain" <<< "$sans" || { error "证书未包含请求的域名"; return 1; }
    if [[ "$wildcard" == 1 ]]; then
        grep -Fxq "DNS:*.$domain" <<< "$sans" || { error "证书未包含请求的泛域名"; return 1; }
    fi
}

deploy_certificate() {
    local main=$1 wildcard=${2:-0}
    local base=${main#\*.}
    local source="$ACME_HOME/${main}_ecc" key="$CERT_DIR/$base.key" cert="$CERT_DIR/$base.crt"
    validate_pair "$source/fullchain.cer" "$source/$main.key" "$base" "$wildcard" || return 1
    [[ ! -L "$key" && ! -L "$cert" ]] || { error "证书目标不能是符号链接"; return 1; }
    local had_key=0 had_cert=0 backup
    backup=$(mktemp -d "$STATE_DIR/deploy-$base.XXXXXX") || return 1
    if [[ -e "$key" ]]; then cp -p "$key" "$backup/old.key" || return 1; had_key=1; fi
    if [[ -e "$cert" ]]; then cp -p "$cert" "$backup/old.crt" || return 1; had_cert=1; fi
    # Existing modes are retained by upstream. Set restrictive modes before copying.
    touch "$key" "$cert" && chmod 600 "$key" && chmod 644 "$cert" || return 1
    if acme --install-cert -d "$main" --ecc --key-file "$key" --fullchain-file "$cert" --reloadcmd "$reload_cmd"; then
        rm -rf -- "$backup"
        info "证书已部署: $cert"
        info "私钥路径:   $key"
        return 0
    fi
    local restored=1
    if [[ "$had_key" == 1 ]]; then cp -p "$backup/old.key" "$key" || restored=0
    else rm -f "$key" || restored=0; fi
    if [[ "$had_cert" == 1 ]]; then cp -p "$backup/old.crt" "$cert" || restored=0
    else rm -f "$cert" || restored=0; fi
    if [[ "$restored" == 1 ]]; then error "证书部署或服务重载失败，已恢复原证书文件，请检查上方输出"
    else error "证书恢复未完成，请立即检查 $CERT_DIR；备份保留在 $backup"; fi
    return 1
}

issue_certificate() {
    local mode=$1 domain main reload_cmd='' family result=0
    require_ready || return 1
    read_domain || return 1
    main=$domain
    if [[ -f "$ACME_HOME/*.${domain}_ecc/*.$domain.conf" ]]; then
        if [[ "$mode" != wildcard || -f "$ACME_HOME/${domain}_ecc/$domain.conf" ]]; then
            error "检测到旧版泛域名配置，请先核对菜单 6 中的证书，避免不同配置覆盖同一部署路径"
            return 1
        fi
        main="*.$domain"
        info "沿用旧版泛域名证书名称: $main"
    fi
    local -a args=(--issue -d "$main" --keylength ec-256)
    case "$mode" in
        standalone)
            check_http_port || return 1
            info "请确认域名 A / AAAA 指向此服务器，且公网 TCP 80 可达。"
            read -r -p "验证监听地址族 [1: IPv4 / 2: IPv6，默认 1]: " family || return 1
            case "$family" in
                ""|1) args+=(--standalone) ;;
                2) args+=(--standalone --listen-v6) ;;
                *) error "无效地址族"; return 1 ;;
            esac ;;
        dns|wildcard)
            args+=(--dns dns_cf)
            if [[ "$mode" == wildcard ]]; then
                if [[ "$main" == "$domain" ]]; then args+=(-d "*.$domain")
                else args+=(-d "$domain"); fi
            fi
            read_cf_credentials || return 1 ;;
        *) error "无效申请模式"; return 1 ;;
    esac
    read_reload "$main" || return 1
    acme "${args[@]}" || result=$?
    case "$result" in
        0) ;;
        2) info "acme.sh 跳过了重复签发，将校验证书后部署。" ;;
        *) error "证书申请失败（退出码 $result），已停止部署"; return 1 ;;
    esac
    local wildcard=0
    [[ "$mode" != wildcard ]] || wildcard=1
    deploy_certificate "$main" "$wildcard"
}

read_cf_credentials() {
    local method token zone
    info "Cloudflare 凭据: 1. API Token（推荐）  2. 复用 acme.sh 已保存的凭据"
    read -r -p "请选择 [1]: " method || return 1
    case "$method" in
        ""|1)
            read -r -s -p "API Token: " token || return 1
            printf '\n'
            [[ -n "$token" && ! "$token" =~ [[:space:]] ]] || { error "Token 不能为空或包含空白"; return 1; }
            read -r -p "域名的 Zone ID: " zone || return 1
            [[ "$zone" =~ ^[0-9a-fA-F]{32}$ ]] || { error "Zone ID 应为 32 位十六进制字符"; return 1; }
            # Scope the token to one zone; do not print or pass it in command arguments.
            export CF_Token="$token" CF_Zone_ID="$zone"
            unset CF_Key CF_Email CF_Account_ID
            ;;
        2) unset CF_Token CF_Zone_ID CF_Key CF_Email CF_Account_ID ;;
        *) error "无效选项"; return 1 ;;
    esac
}

list_certificates() {
    installed || { error "尚未安装 acme.sh"; return 1; }
    acme --list
}

renew_certificates() {
    require_ready || return 1
    acme --cron || { error "续期检查未完成，请检查上方输出"; return 1; }
    info "续期检查完成；未到续期时间的证书会自动跳过。"
}

revoke_certificate() {
    local domain input confirm config
    require_ready || return 1
    list_certificates || return 1
    read -r -p "请输入 Main_Domain 中的证书名称: " input || return 1
    domain=${input,,}
    valid_domain "${domain#\*.}" || { error "无效证书名称"; return 1; }
    config="$ACME_HOME/${domain}_ecc/$domain.conf"
    [[ -f "$config" && ! -L "$ACME_HOME/${domain}_ecc" ]] ||
        { error "未找到对应的 ECC 证书"; return 1; }
    info "将向 CA 撤销证书并停止续期。已部署的证书文件会保留，相关服务需要改用有效证书。"
    read -r -p "确认撤销请输入完整证书名称: " confirm || return 1
    [[ "$confirm" == "$domain" ]] || { info "已取消"; return 0; }
    acme --revoke -d "$domain" --ecc || { error "撤销失败，未移除续期配置"; return 1; }
    acme --remove -d "$domain" --ecc || { error "证书已撤销，但移除续期配置失败"; return 1; }
    info "证书已撤销并移出续期列表。历史文件仍保留在 $ACME_HOME 和 $CERT_DIR。"
}

switch_ca() {
    installed || { error "请先安装 acme.sh"; return 1; }
    local provider
    info "1. Let's Encrypt（默认）"
    info "2. ZeroSSL（账户可能需要邮箱 / EAB）"
    read -r -p "请选择 [1]: " provider || return 1
    case "$provider" in
        ""|1) acme --set-default-ca --server letsencrypt || return 1 ;;
        2) acme --set-default-ca --server zerossl || return 1 ;;
        *) error "无效选项"; return 1 ;;
    esac
    info "默认 CA 已更新，仅影响之后的新申请；已有证书仍按各自记录续期。"
}

uninstall_manager() {
    local confirm
    installed || { error "尚未安装 acme.sh"; return 1; }
    info "卸载将停止此目录的自动续期，并保留证书、私钥、账户资料及续期日志。"
    read -r -p "确认卸载请输入 UNINSTALL: " confirm || return 1
    [[ "$confirm" == UNINSTALL ]] || { info "已取消"; return 0; }
    ensure_private_dirs || return 1
    configure_schedule remove || return 1
    acme --uninstall --nocron || { error "客户端卸载失败，自动续期已停止"; return 1; }
    info "已卸载。保留目录: $ACME_HOME、$CERT_DIR"
}

menu() {
    local choice version
    while :; do
        printf '\n=== ACME 证书管理工具 ===\n'
        if installed; then
            version=$(acme --version 2>/dev/null | tail -n 1)
            info "安装状态: 已安装 $version"
        else info "安装状态: 未安装"; fi
        printf '\n%s\n' \
            "1. 安装 / 修复 acme.sh 与自动续期" \
            "2. 卸载 acme.sh（保留证书）" \
            "3. 申请单域名证书（HTTP / 80）" \
            "4. 申请单域名证书（Cloudflare DNS）" \
            "5. 申请泛域名证书（Cloudflare DNS）" \
            "6. 查看证书列表" \
            "7. 撤销证书并停止续期" \
            "8. 检查并续期证书" \
            "9. 切换新申请使用的 CA" \
            "0. 退出" \
            "=========================="
        read -r -p "请输入选项编号: " choice || return 0
        case "$choice" in
            0) return 0 ;;
            1|2|3|4|5|6|7|8|9) ;;
            *) info "无效选项"; continue ;;
        esac
        ensure_lock_tool || { error "无法准备操作锁"; return 1; }
        local -a operation
        case "$choice" in
            1) operation=(install_manager) ;;
            2) operation=(uninstall_manager) ;;
            3) operation=(issue_certificate standalone) ;;
            4) operation=(issue_certificate dns) ;;
            5) operation=(issue_certificate wildcard) ;;
            6) operation=(list_certificates) ;;
            7) operation=(revoke_certificate) ;;
            8) operation=(renew_certificates) ;;
            9) operation=(switch_ca) ;;
        esac
        with_lock "${operation[@]}" || info "操作未完成，请检查上方错误信息。"
        read -r -p "按 Enter 键继续..." choice || return 0
    done
}

main() {
    set -o pipefail
    if [[ "${1:-}" == --help ]]; then
        info "用法: bash acme.sh"
        info "交互式证书管理；支持 Debian / Ubuntu、RHEL 系发行版与 Alpine。"
        return 0
    fi
    [[ $# == 0 ]] || { error "未知参数，使用 --help 查看帮助"; return 1; }
    [[ $EUID == 0 ]] || { error "请使用 root 运行"; return 1; }
    detect_system || return 1
    menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
