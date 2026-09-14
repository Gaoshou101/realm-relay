#!/usr/bin/env bash
# =========================================================
# Realm 简易管理与一键安装脚本
# 项目地址: https://github.com/Gaoshou101/realm-relay
# =========================================================

set -e

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

REALM_BIN="/usr/local/bin/realm"
REALM_CONF_DIR="/etc/realm"
REALM_CONF="${REALM_CONF_DIR}/config.toml"
SYSTEMD_SERVICE="/etc/systemd/system/realm.service"
SCRIPT_INSTALL_PATH="/usr/local/bin/realm.sh"

FALLBACK_VERSION="v2.9.6"
SHA256_AMD64="b1cc335547bea8bb2a88178bef12ec7f2363e36200e7ea1d4e1e67627929bf65"
SHA256_ARM64="f4c0318dd86854da483dcb7645b4f39cae2cc3f91c688fef969d53220b949488"

info() { echo -e "${BLUE}[INFO]${PLAIN} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${PLAIN} $1"; }
warn() { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }
error() { echo -e "${RED}[ERROR]${PLAIN} $1"; }

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "此脚本必须以 root 用户执行！请使用 sudo 或切换 root。"
        exit 1
    fi
}

check_sys() {
    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64|amd64)
            REALM_ARCH="x86_64-unknown-linux-musl"
            EXPECTED_SHA256="${SHA256_AMD64}"
            ;;
        aarch64|arm64)
            REALM_ARCH="aarch64-unknown-linux-musl"
            EXPECTED_SHA256="${SHA256_ARM64}"
            ;;
        *)
            error "暂不支持当前 CPU 架构: ${ARCH}"
            exit 1
            ;;
    esac
}

install_deps() {
    info "检查并安装基础依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y curl ca-certificates tar iproute2 procps >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates tar iproute procps-ng >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates tar iproute procps-ng >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates tar iproute2 procps >/dev/null 2>&1
    fi
}

check_port_used() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        if ss -lntH "sport = :${port}" 2>/dev/null | grep -q .; then
            return 0
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -lnt | grep -E ":${port}\b" >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

open_firewall() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${port}/tcp" comment "realm-relay" >/dev/null 2>&1 || true
        info "已自动放行 UFW TCP 端口: ${port}"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "已自动放行 firewalld TCP 端口: ${port}"
    fi
}

get_current_listen_port() {
    if [[ -f "${REALM_CONF}" ]]; then
        grep -E 'listen\s*=' "${REALM_CONF}" | head -n1 | sed -E 's/.*:([0-9]+)".*/\1/'
    fi
}

get_current_remote() {
    if [[ -f "${REALM_CONF}" ]]; then
        grep -E 'remote\s*=' "${REALM_CONF}" | head -n1 | sed -E 's/.*"(.*)".*/\1/'
    fi
}

install_self() {
    # 将自身拷贝到系统路径，方便后续直接 realm.sh 调用
    local self_path
    self_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    if [[ -f "${self_path}" && "${self_path}" != "${SCRIPT_INSTALL_PATH}" ]]; then
        cp -f "${self_path}" "${SCRIPT_INSTALL_PATH}"
        chmod +x "${SCRIPT_INSTALL_PATH}"
        ln -sf "${SCRIPT_INSTALL_PATH}" /usr/local/bin/realm-cli 2>/dev/null || true
    fi
}

install_realm() {
    check_root
    check_sys
    install_deps

    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "${BLUE}             安装与配置 Realm 中转               ${PLAIN}"
    echo -e "${BLUE}=================================================${PLAIN}"

    local listen_port=""
    local remote_host=""
    local remote_port=""

    # 1. 输入本地监听端口
    while true; do
        read -r -p "请输入本机中转监听端口 (默认: 25443): " input_port
        listen_port="${input_port:-25443}"
        if ! validate_port "${listen_port}"; then
            error "端口必须是 1-65535 之间的有效数字，请重新输入！"
            continue
        fi
        if check_port_used "${listen_port}"; then
            warn "警告: 端口 ${listen_port} 当前已被占用！"
            read -r -p "确定仍要使用该端口吗？(y/N): " force_use
            if [[ ! "${force_use}" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi
        break
    done

    # 2. 输入落地端目标地址
    while true; do
        read -r -p "请输入落地机 IP 或域名 (例如: 1.2.3.4 或 remote.example.com): " input_host
        remote_host="$(echo "${input_host}" | tr -d ' ')"
        if [[ -z "${remote_host}" ]]; then
            error "落地机地址不能为空，请重新输入！"
            continue
        fi
        break
    done

    # 3. 输入落地端目标端口
    while true; do
        read -r -p "请输入落地机服务端口 (默认: 24443): " input_rport
        remote_port="${input_rport:-24443}"
        if ! validate_port "${remote_port}"; then
            error "端口必须是 1-65535 之间的有效数字，请重新输入！"
            continue
        fi
        break
    done

    echo
    info "配置确认:"
    echo -e "  - 本机中转监听端口: ${GREEN}${listen_port}${PLAIN} (TCP)"
    echo -e "  - 落地目标主机:     ${GREEN}${remote_host}${PLAIN}"
    echo -e "  - 落地目标端口:     ${GREEN}${remote_port}${PLAIN} (TCP)"
    echo

    # 下载 Realm
    info "正在检测最新版本..."
    local tag=""
    tag="$(curl -fsSL --connect-timeout 8 https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    if [[ -z "${tag}" ]]; then
        tag="${FALLBACK_VERSION}"
        warn "未能实时获取最新 Release，将使用备用版本: ${tag}"
    fi

    local download_url="https://github.com/zhboner/realm/releases/download/${tag}/realm-${REALM_ARCH}.tar.gz"
    info "正在下载 Realm (${tag} - ${ARCH})..."

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"' EXIT

    if ! curl -fL --retry 3 --connect-timeout 15 "${download_url}" -o "${tmp_dir}/realm.tar.gz"; then
        error "从 GitHub 下载失败，请检查本机网络或代理设置！"
        exit 1
    fi

    # 如果是已知 fallback 版本，校验 sha256
    if [[ "${tag}" == "${FALLBACK_VERSION}" && -n "${EXPECTED_SHA256}" ]]; then
        info "校验官方包 SHA256 哈希..."
        echo "${EXPECTED_SHA256}  ${tmp_dir}/realm.tar.gz" | sha256sum -c - || {
            error "文件完整性校验失败，下载内容不匹配！"
            exit 1
        }
    fi

    tar -xzf "${tmp_dir}/realm.tar.gz" -C "${tmp_dir}"
    install -m 0755 "${tmp_dir}/realm" "${REALM_BIN}"

    # 创建配置目录与配置文件
    mkdir -p "${REALM_CONF_DIR}"
    if [[ -f "${REALM_CONF}" ]]; then
        cp -f "${REALM_CONF}" "${REALM_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    cat > "${REALM_CONF}" <<EOF
[log]
level = "warn"
output = "stdout"

[network]
no_tcp = false
use_udp = false
tcp_timeout = 5
tcp_keepalive = 15
tcp_keepalive_probe = 3
send_proxy = false
accept_proxy = false

[[endpoints]]
listen = "0.0.0.0:${listen_port}"
remote = "${remote_host}:${remote_port}"
EOF

    # 配置 systemd 服务
    cat > "${SYSTEMD_SERVICE}" <<'EOF'
[Unit]
Description=Realm High-Performance TCP Relay
Documentation=https://github.com/zhboner/realm
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm >/dev/null 2>&1 || true
    systemctl restart realm

    sleep 1.5
    open_firewall "${listen_port}"
    install_self

    if systemctl is-active realm >/dev/null 2>&1; then
        echo
        success "Realm 安装并启动成功！"
        echo -e "中转转发规则: ${GREEN}0.0.0.0:${listen_port}${PLAIN} -> ${GREEN}${remote_host}:${remote_port}${PLAIN}"
        echo -e "管理命令: 以后在任意终端直接运行 ${YELLOW}realm.sh${PLAIN} 即可打开管理菜单。"
    else
        error "Realm 服务启动失败，请检查日志: journalctl -u realm -n 30 --no-pager"
    fi
}

show_status() {
    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "${BLUE}               Realm 运行状态                    ${PLAIN}"
    echo -e "${BLUE}=================================================${PLAIN}"

    if [[ ! -f "${REALM_BIN}" ]]; then
        warn "未检测到 Realm 二进制文件，可能尚未安装。"
        return
    fi

    local version
    version="$(${REALM_BIN} --version 2>/dev/null || echo "未知")"
    echo -e "核心版本:    ${GREEN}${version}${PLAIN}"

    local is_active
    if systemctl is-active realm >/dev/null 2>&1; then
        is_active="${GREEN}运行中 (Active)${PLAIN}"
    else
        is_active="${RED}已停止 (Inactive)${PLAIN}"
    fi
    echo -e "服务状态:    ${is_active}"

    local is_enabled
    if systemctl is-enabled realm >/dev/null 2>&1; then
        is_enabled="${GREEN}已启用 (Enabled)${PLAIN}"
    else
        is_enabled="${YELLOW}未启用 (Disabled)${PLAIN}"
    fi
    echo -e "开机自启:    ${is_enabled}"

    if [[ -f "${REALM_CONF}" ]]; then
        local l_port r_target
        l_port="$(get_current_listen_port)"
        r_target="$(get_current_remote)"
        echo -e "当前配置:    ${GREEN}0.0.0.0:${l_port:-未知}${PLAIN} -> ${GREEN}${r_target:-未知}${PLAIN}"
        if [[ -n "${l_port}" ]] && command -v ss >/dev/null 2>&1; then
            echo -e "监听占用:    $(ss -lntp "sport = :${l_port}" 2>/dev/null | tail -n +2 | tr -s ' ' || echo '未检测到监听')"
        fi
    fi
    echo
}

show_realtime_log() {
    info "正在查看 Realm 实时日志 (按 Ctrl+C 退出)..."
    journalctl -u realm -f
}

show_recent_log() {
    echo -e "${BLUE}================== 最近 50 条日志 ==================${PLAIN}"
    journalctl -u realm -n 50 --no-pager
    echo -e "${BLUE}====================================================${PLAIN}"
}

modify_port() {
    check_root
    if [[ ! -f "${REALM_CONF}" ]]; then
        error "未找到配置文件 ${REALM_CONF}，请先安装！"
        return 1
    fi

    local cur_port
    cur_port="$(get_current_listen_port)"
    info "当前本机监听端口为: ${GREEN}${cur_port:-未知}${PLAIN}"

    local new_port=""
    while true; do
        read -r -p "请输入新的监听端口 (1-65535): " new_port
        if ! validate_port "${new_port}"; then
            error "端口必须是 1-65535 之间的有效数字，请重新输入！"
            continue
        fi
        if [[ "${new_port}" == "${cur_port}" ]]; then
            warn "新端口与当前端口相同，无须修改。"
            return 0
        fi
        if check_port_used "${new_port}"; then
            warn "警告: 端口 ${new_port} 已被其他程序占用！"
            read -r -p "仍要强制使用该端口吗？(y/N): " force_use
            if [[ ! "${force_use}" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi
        break
    done

    sed -i -E "s/listen\s*=\s*\"0\.0\.0\.0:[0-9]+\"/listen = \"0.0.0.0:${new_port}\"/" "${REALM_CONF}"
    open_firewall "${new_port}"

    info "配置已修改，正在重启 Realm..."
    systemctl restart realm
    sleep 1

    if systemctl is-active realm >/dev/null 2>&1; then
        success "监听端口已成功修改为: ${GREEN}${new_port}${PLAIN} 并已重启生效！"
    else
        error "修改后服务启动异常，请查看日志！"
    fi
}

modify_remote() {
    check_root
    if [[ ! -f "${REALM_CONF}" ]]; then
        error "未找到配置文件 ${REALM_CONF}，请先安装！"
        return 1
    fi

    local cur_remote
    cur_remote="$(get_current_remote)"
    info "当前落地端目标为: ${GREEN}${cur_remote:-未知}${PLAIN}"

    local new_host=""
    local new_rport=""

    read -r -p "请输入新的落地机 IP 或域名 (回车保持原样): " input_host
    input_host="$(echo "${input_host}" | tr -d ' ')"
    if [[ -n "${input_host}" ]]; then
        new_host="${input_host}"
    else
        new_host="$(echo "${cur_remote}" | cut -d: -f1)"
    fi

    while true; do
        read -r -p "请输入新的落地机端口 (回车保持原样): " input_rport
        input_rport="$(echo "${input_rport}" | tr -d ' ')"
        if [[ -z "${input_rport}" ]]; then
            new_rport="$(echo "${cur_remote}" | cut -d: -f2)"
            break
        fi
        if ! validate_port "${input_rport}"; then
            error "端口必须是 1-65535 之间的有效数字！"
            continue
        fi
        new_rport="${input_rport}"
        break
    done

    local new_target="${new_host}:${new_rport}"
    sed -i -E "s/remote\s*=\s*\".*\"/remote = \"${new_target}\"/" "${REALM_CONF}"

    info "落地配置已修改为: ${new_target}，正在重启 Realm..."
    systemctl restart realm
    sleep 1

    if systemctl is-active realm >/dev/null 2>&1; then
        success "落地端目标已成功更新并生效！"
    else
        error "修改后服务启动异常，请查看日志！"
    fi
}

restart_service() {
    check_root
    info "正在重启 Realm..."
    systemctl restart realm
    sleep 1
    if systemctl is-active realm >/dev/null 2>&1; then
        success "Realm 重启成功！"
    else
        error "Realm 重启失败！"
    fi
}

stop_service() {
    check_root
    info "正在停止 Realm..."
    systemctl stop realm
    success "Realm 已停止。"
}

start_service() {
    check_root
    info "正在启动 Realm..."
    systemctl start realm
    sleep 1
    if systemctl is-active realm >/dev/null 2>&1; then
        success "Realm 启动成功！"
    else
        error "Realm 启动失败！"
    fi
}

uninstall_realm() {
    check_root
    read -r -p "确定要彻底卸载 Realm 吗？(y/N): " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        info "已取消卸载。"
        return 0
    fi

    info "正在卸载 Realm..."
    systemctl stop realm >/dev/null 2>&1 || true
    systemctl disable realm >/dev/null 2>&1 || true
    rm -f "${SYSTEMD_SERVICE}"
    systemctl daemon-reload

    rm -f "${REALM_BIN}"
    rm -rf "${REALM_CONF_DIR}"
    rm -f "${SCRIPT_INSTALL_PATH}" /usr/local/bin/realm-cli 2>/dev/null || true

    success "Realm 及所有配置文件已彻底清除！"
}

menu() {
    clear 2>/dev/null || true
    echo -e "${GREEN}=================================================${PLAIN}"
    echo -e "${GREEN}        Realm 高性能 TCP 端口中转管理脚本        ${PLAIN}"
    echo -e "${GREEN}        项目: https://github.com/Gaoshou101/realm-relay  ${PLAIN}"
    echo -e "${GREEN}=================================================${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 安装 / 重装 Realm (自选监听与落地端口)"
    echo -e "  ${GREEN}2.${PLAIN} 查看运行状态"
    echo -e "  ${GREEN}3.${PLAIN} 查看实时运行日志 (Ctrl+C 退出)"
    echo -e "  ${GREEN}4.${PLAIN} 查看最近 50 条日志"
    echo -e "  ${GREEN}5.${PLAIN} 修改本机中转监听端口"
    echo -e "  ${GREEN}6.${PLAIN} 修改落地目标地址与端口"
    echo -e "  ${GREEN}7.${PLAIN} 重启 Realm"
    echo -e "  ${GREEN}8.${PLAIN} 停止 Realm"
    echo -e "  ${GREEN}9.${PLAIN} 启动 Realm"
    echo -e "  ${GREEN}10.${PLAIN} 彻底卸载 Realm"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    echo -e "${GREEN}=================================================${PLAIN}"

    if [[ -f "${REALM_CONF}" ]]; then
        local lp rt
        lp="$(get_current_listen_port)"
        rt="$(get_current_remote)"
        local st
        if systemctl is-active realm >/dev/null 2>&1; then
            st="${GREEN}运行中${PLAIN}"
        else
            st="${RED}已停止${PLAIN}"
        fi
        echo -e "当前状态: [${st}]  监听端口: ${YELLOW}${lp:-无}${PLAIN} -> 目标: ${YELLOW}${rt:-无}${PLAIN}"
        echo -e "${GREEN}=================================================${PLAIN}"
    fi

    read -r -p "请输入选项 [0-10]: " num
    case "${num}" in
        1) install_realm ;;
        2) show_status ;;
        3) show_realtime_log ;;
        4) show_recent_log ;;
        5) modify_port ;;
        6) modify_remote ;;
        7) restart_service ;;
        8) stop_service ;;
        9) start_service ;;
        10) uninstall_realm ;;
        0) exit 0 ;;
        *) error "请输入有效选项！" ;;
    esac
}

# 支持非交互命令行直接调用，也支持无参数菜单
action="${1:-}"
case "${action}" in
    install)
        install_realm
        ;;
    status)
        show_status
        ;;
    log|logs)
        show_realtime_log
        ;;
    log-recent)
        show_recent_log
        ;;
    port)
        modify_port
        ;;
    remote)
        modify_remote
        ;;
    restart)
        restart_service
        ;;
    stop)
        stop_service
        ;;
    start)
        start_service
        ;;
    uninstall)
        uninstall_realm
        ;;
    *)
        menu
        ;;
esac
