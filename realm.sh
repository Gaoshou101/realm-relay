#!/usr/bin/env bash
# =========================================================
# Realm 简易管理与一键安装脚本 (多转发/多落地支持版)
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
        apt-get install -y curl ca-certificates tar iproute2 procps python3 >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates tar iproute procps-ng python3 >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates tar iproute procps-ng python3 >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates tar iproute2 procps python3 >/dev/null 2>&1
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

install_self() {
    local self_path
    self_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    if [[ -f "${self_path}" && "${self_path}" != "${SCRIPT_INSTALL_PATH}" ]]; then
        cp -f "${self_path}" "${SCRIPT_INSTALL_PATH}"
        chmod +x "${SCRIPT_INSTALL_PATH}"
        ln -sf "${SCRIPT_INSTALL_PATH}" /usr/local/bin/realm-cli 2>/dev/null || true
    fi
}

# ==================== Python 配置解析与写入助手 ====================
py_ensure_base_conf() {
    mkdir -p "${REALM_CONF_DIR}"
    if [[ ! -f "${REALM_CONF}" ]]; then
        cat > "${REALM_CONF}" <<'EOF'
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
EOF
    fi
}

get_rules_count() {
    if [[ ! -f "${REALM_CONF}" ]]; then
        echo 0
        return
    fi
    python3 -c '
import re
try:
    with open("'"${REALM_CONF}"'", "r", encoding="utf-8") as f:
        content = f.read()
    rules = re.findall(r"\[\[endpoints\]\][\s\S]*?(?=\[\[endpoints\]\]|$)", content)
    valid = 0
    for r in rules:
        if re.search(r"listen\s*=", r) and re.search(r"remote\s*=", r):
            valid += 1
    print(valid)
except Exception:
    print(0)
' 2>/dev/null || echo 0
}

list_rules_table() {
    if [[ ! -f "${REALM_CONF}" ]]; then
        warn "配置文件不存在。"
        return
    fi
    python3 -c '
import re, subprocess

def get_listener_pids():
    pids = {}
    try:
        out = subprocess.check_output(["ss", "-lntp"], stderr=subprocess.DEVNULL).decode()
        for line in out.splitlines():
            line = line.strip()
            parts = line.split()
            if len(parts) >= 4 and ":" in parts[3]:
                port = parts[3].rsplit(":", 1)[-1]
                pids[port] = parts[-1] if len(parts) > 5 else "LISTEN"
    except Exception:
        pass
    return pids

listener_map = get_listener_pids()

with open("'"${REALM_CONF}"'", "r", encoding="utf-8") as f:
    content = f.read()

rules = re.findall(r"\[\[endpoints\]\][\s\S]*?(?=\[\[endpoints\]\]|$)", content)
items = []
for r in rules:
    m_listen = re.search(r"listen\s*=\s*\"([^\"]+)\"", r)
    m_remote = re.search(r"remote\s*=\s*\"([^\"]+)\"", r)
    if m_listen and m_remote:
        items.append((m_listen.group(1), m_remote.group(1)))

if not items:
    print("\033[33m[!] 当前尚未添加任何中转规则。\033[0m")
else:
    print("\033[36m序号\t本机监听(Listen)\t\t落地目标(Remote)\t\t状态\033[0m")
    print("-----------------------------------------------------------------------")
    for idx, (listen, remote) in enumerate(items, 1):
        port = listen.rsplit(":", 1)[-1]
        active = "\033[32m已监听\033[0m" if port in listener_map else "\033[33m未检测到\033[0m"
        print(f" {idx}\t{listen:<24}\t{remote:<24}\t{active}")
' 2>/dev/null || warn "读取规则列表失败。"
}

# ==================== 规则增删改操作 ====================
add_rule() {
    check_root
    py_ensure_base_conf

    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "${BLUE}               添加新中转转发规则                ${PLAIN}"
    echo -e "${BLUE}=================================================${PLAIN}"

    local listen_port=""
    local remote_host=""
    local remote_port=""

    # 1. 本机中转端口
    while true; do
        read -r -p "请输入本机中转监听端口 (例如: 25443): " input_port
        listen_port="${input_port:-}"
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

    # 2. 落地端目标地址
    while true; do
        read -r -p "请输入落地机 IP 或域名 (例如: 1.2.3.4 或 remote.example.com): " input_host
        remote_host="$(echo "${input_host}" | tr -d ' ')"
        if [[ -z "${remote_host}" ]]; then
            error "落地机地址不能为空，请重新输入！"
            continue
        fi
        break
    done

    # 3. 落地端目标端口
    while true; do
        read -r -p "请输入落地机目标端口 (例如: 24443): " input_rport
        remote_port="${input_rport:-24443}"
        if ! validate_port "${remote_port}"; then
            error "端口必须是 1-65535 之间的有效数字，请重新输入！"
            continue
        fi
        break
    done

    cat >> "${REALM_CONF}" <<EOF

[[endpoints]]
listen = "0.0.0.0:${listen_port}"
remote = "${remote_host}:${remote_port}"
EOF

    open_firewall "${listen_port}"

    info "正在重启 Realm 使新规则生效..."
    systemctl restart realm || true
    sleep 1

    if systemctl is-active realm >/dev/null 2>&1; then
        success "规则添加成功！当前中转: 0.0.0.0:${listen_port} -> ${remote_host}:${remote_port}"
    else
        error "Realm 重启异常，请检查配置或日志: realm.sh (菜单选择查看日志)"
    fi
}

del_rule() {
    check_root
    local total
    total="$(get_rules_count)"
    if [ "${total}" -le 0 ]; then
        warn "当前没有可删除的转发规则！"
        return
    fi

    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "${BLUE}                 删除中转规则                    ${PLAIN}"
    echo -e "${BLUE}=================================================${PLAIN}"
    list_rules_table
    echo

    local del_idx=""
    while true; do
        read -r -p "请输入要删除的规则序号 [1-${total}] (输入 0 取消): " del_idx
        if [[ "${del_idx}" == "0" ]]; then
            info "已取消删除。"
            return
        fi
        if [[ ! "${del_idx}" =~ ^[0-9]+$ ]] || [ "${del_idx}" -lt 1 ] || [ "${del_idx}" -gt "${total}" ]; then
            error "请输入有效的规则序号！"
            continue
        fi
        break
    done

    python3 -c '
import re, sys
target_idx = int("'"${del_idx}"'") - 1
conf_file = "'"${REALM_CONF}"'"

with open(conf_file, "r", encoding="utf-8") as f:
    content = f.read()

header = re.split(r"\[\[endpoints\]\]", content, maxsplit=1)[0].rstrip()
rules = re.findall(r"\[\[endpoints\]\][\s\S]*?(?=\[\[endpoints\]\]|$)", content)

valid_rules = []
for r in rules:
    if re.search(r"listen\s*=", r) and re.search(r"remote\s*=", r):
        valid_rules.append(r.strip())

if target_idx < 0 or target_idx >= len(valid_rules):
    sys.exit(1)

deleted = valid_rules.pop(target_idx)

new_content = header + "\n\n"
if valid_rules:
    new_content += "\n\n".join(valid_rules) + "\n"

with open(conf_file, "w", encoding="utf-8") as f:
    f.write(new_content)
'
    success "规则 [${del_idx}] 已删除，正在重启服务..."
    systemctl restart realm || true
}

modify_rule() {
    check_root
    local total
    total="$(get_rules_count)"
    if [ "${total}" -le 0 ]; then
        warn "当前没有可修改的转发规则！"
        return
    fi

    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "${BLUE}                 修改中转规则                    ${PLAIN}"
    echo -e "${BLUE}=================================================${PLAIN}"
    list_rules_table
    echo

    local mod_idx=""
    while true; do
        read -r -p "请输入要修改的规则序号 [1-${total}] (输入 0 取消): " mod_idx
        if [[ "${mod_idx}" == "0" ]]; then
            info "已取消修改。"
            return
        fi
        if [[ ! "${mod_idx}" =~ ^[0-9]+$ ]] || [ "${mod_idx}" -lt 1 ] || [ "${mod_idx}" -gt "${total}" ]; then
            error "请输入有效的规则序号！"
            continue
        fi
        break
    done

    # 读取原有参数
    local cur_info
    cur_info="$(python3 -c '
import re
idx = int("'"${mod_idx}"'") - 1
with open("'"${REALM_CONF}"'", "r", encoding="utf-8") as f:
    content = f.read()
rules = re.findall(r"\[\[endpoints\]\][\s\S]*?(?=\[\[endpoints\]\]|$)", content)
valid = []
for r in rules:
    m_listen = re.search(r"listen\s*=\s*\"([^\"]+)\"", r)
    m_remote = re.search(r"remote\s*=\s*\"([^\"]+)\"", r)
    if m_listen and m_remote:
        valid.append((m_listen.group(1), m_remote.group(1)))
if 0 <= idx < len(valid):
    print(f"{valid[idx][0]}|{valid[idx][1]}")
')"
    local old_listen old_remote
    old_listen="$(echo "${cur_info}" | cut -d'|' -f1)"
    old_remote="$(echo "${cur_info}" | cut -d'|' -f2)"
    local old_port
    old_port="$(echo "${old_listen}" | rsplit=":" cut -d':' -f2)"

    echo
    info "当前选中规则 [${mod_idx}]: ${old_listen} -> ${old_remote}"

    local new_port=""
    while true; do
        read -r -p "请输入新的本机监听端口 (回车保持原端口 ${old_port}): " input_port
        input_port="${input_port:-${old_port}}"
        if ! validate_port "${input_port}"; then
            error "端口必须是 1-65535 之间的有效数字！"
            continue
        fi
        new_port="${input_port}"
        break
    done

    local new_remote=""
    read -r -p "请输入新的落地目标 [IP:端口] (回车保持原目标 ${old_remote}): " input_remote
    input_remote="$(echo "${input_remote}" | tr -d ' ')"
    new_remote="${input_remote:-${old_remote}}"

    python3 -c '
import re
target_idx = int("'"${mod_idx}"'") - 1
new_listen = "0.0.0.0:'"${new_port}"'"
new_remote = "'"${new_remote}"'"
conf_file = "'"${REALM_CONF}"'"

with open(conf_file, "r", encoding="utf-8") as f:
    content = f.read()

header = re.split(r"\[\[endpoints\]\]", content, maxsplit=1)[0].rstrip()
rules = re.findall(r"\[\[endpoints\]\][\s\S]*?(?=\[\[endpoints\]\]|$)", content)

valid_rules = []
for r in rules:
    if re.search(r"listen\s*=", r) and re.search(r"remote\s*=", r):
        valid_rules.append(r.strip())

if 0 <= target_idx < len(valid_rules):
    valid_rules[target_idx] = f"[[endpoints]]\nlisten = \"{new_listen}\"\nremote = \"{new_remote}\""

new_content = header + "\n\n" + "\n\n".join(valid_rules) + "\n"
with open(conf_file, "w", encoding="utf-8") as f:
    f.write(new_content)
'
    open_firewall "${new_port}"
    info "正在重启 Realm 使修改生效..."
    systemctl restart realm || true
    success "规则 [${mod_idx}] 修改完成！新配置: 0.0.0.0:${new_port} -> ${new_remote}"
}

# ==================== 基础安装与服务管理 ====================
install_realm() {
    check_root
    check_sys
    install_deps

    echo -e "${BLUE}=================================================${PLAIN}"
    echo -e "${BLUE}             全新安装 / 重装 Realm              ${PLAIN}"
    echo -e "${BLUE}=================================================${PLAIN}"

    info "正在检测最新版本..."
    local tag=""
    tag="$(curl -fsSL --connect-timeout 8 https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    if [[ -z "${tag}" ]]; then
        tag="${FALLBACK_VERSION}"
        warn "未能实时获取最新 Release，使用稳定版本: ${tag}"
    fi

    local download_url="https://github.com/zhboner/realm/releases/download/${tag}/realm-${REALM_ARCH}.tar.gz"
    info "正在下载 Realm (${tag} - ${ARCH})..."

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"' EXIT

    if ! curl -fL --retry 3 --connect-timeout 15 "${download_url}" -o "${tmp_dir}/realm.tar.gz"; then
        error "从 GitHub 下载失败，请检查网络！"
        exit 1
    fi

    if [[ "${tag}" == "${FALLBACK_VERSION}" && -n "${EXPECTED_SHA256}" ]]; then
        info "校验官方包 SHA256..."
        echo "${EXPECTED_SHA256}  ${tmp_dir}/realm.tar.gz" | sha256sum -c - || {
            error "文件完整性校验失败！"
            exit 1
        }
    fi

    tar -xzf "${tmp_dir}/realm.tar.gz" -C "${tmp_dir}"
    install -m 0755 "${tmp_dir}/realm" "${REALM_BIN}"

    # 创建基础配置
    py_ensure_base_conf

    # 询问是否立即添加第一条转发规则
    echo
    read -r -p "是否立即添加第一条转发规则？(Y/n): " init_rule
    if [[ ! "${init_rule}" =~ ^[Nn]$ ]]; then
        local l_port="" r_host="" r_port=""
        while true; do
            read -r -p "请输入本机监听端口 (默认: 25443): " input_p
            l_port="${input_p:-25443}"
            if validate_port "${l_port}"; then break; fi
            error "端口不合法，请重新输入！"
        done

        while true; do
            read -r -p "请输入落地机 IP 或域名 (例如: 1.2.3.4): " input_h
            r_host="$(echo "${input_h}" | tr -d ' ')"
            if [[ -n "${r_host}" ]]; then break; fi
            error "落地地址不能为空！"
        done

        while true; do
            read -r -p "请输入落地机端口 (默认: 24443): " input_rp
            r_port="${input_rp:-24443}"
            if validate_port "${r_port}"; then break; fi
            error "端口不合法，请重新输入！"
        done

        cat >> "${REALM_CONF}" <<EOF

[[endpoints]]
listen = "0.0.0.0:${l_port}"
remote = "${r_host}:${r_port}"
EOF
        open_firewall "${l_port}"
    fi

    # systemd unit
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
    install_self

    echo
    success "Realm 核心安装完成！"
    echo -e "管理提示: 以后在任何终端直接输入 ${YELLOW}realm.sh${PLAIN} 即可唤出管理菜单。"
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
    echo
    echo -e "${BLUE}[当前中转规则列表]${PLAIN}"
    list_rules_table
    echo
}

uninstall_realm() {
    check_root
    read -r -p "确定要彻底卸载 Realm 吗？所有转发配置将被清除 (y/N): " confirm
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

# ==================== 多级菜单架构 ====================

menu_rules() {
    while true; do
        echo -e "${GREEN}---------------- 转发规则管理 ----------------${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 查看所有规则与监听状态"
        echo -e "  ${GREEN}2.${PLAIN} 添加新的中转规则 (支持多落地)"
        echo -e "  ${GREEN}3.${PLAIN} 修改已有中转规则"
        echo -e "  ${GREEN}4.${PLAIN} 删除指定中转规则"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        echo -e "${GREEN}----------------------------------------------${PLAIN}"
        read -r -p "请选择 [0-4]: " sub_num
        case "${sub_num}" in
            1)
                echo
                list_rules_table
                echo
                ;;
            2)
                add_rule
                ;;
            3)
                modify_rule
                ;;
            4)
                del_rule
                ;;
            0)
                break
                ;;
            *)
                error "无效选项！"
                ;;
        esac
    done
}

menu_service() {
    while true; do
        echo -e "${GREEN}---------------- 服务运维管理 ----------------${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 重启 Realm"
        echo -e "  ${GREEN}2.${PLAIN} 停止 Realm"
        echo -e "  ${GREEN}3.${PLAIN} 启动 Realm"
        echo -e "  ${GREEN}4.${PLAIN} 设置开机自启"
        echo -e "  ${GREEN}5.${PLAIN} 禁用开机自启"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        echo -e "${GREEN}----------------------------------------------${PLAIN}"
        read -r -p "请选择 [0-5]: " sub_num
        case "${sub_num}" in
            1)
                systemctl restart realm && success "Realm 已重启！" || error "重启失败！"
                ;;
            2)
                systemctl stop realm && success "Realm 已停止！" || error "停止失败！"
                ;;
            3)
                systemctl start realm && success "Realm 已启动！" || error "启动失败！"
                ;;
            4)
                systemctl enable realm && success "已开启开机自启！"
                ;;
            5)
                systemctl disable realm && success "已关闭开机自启！"
                ;;
            0)
                break
                ;;
            *)
                error "无效选项！"
                ;;
        esac
    done
}

menu_logs() {
    while true; do
        echo -e "${GREEN}---------------- 日志与排错 ------------------${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 查看实时运行日志 (按 Ctrl+C 退出)"
        echo -e "  ${GREEN}2.${PLAIN} 查看最近 50 条日志"
        echo -e "  ${GREEN}3.${PLAIN} 查看最近 100 条日志"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        echo -e "${GREEN}----------------------------------------------${PLAIN}"
        read -r -p "请选择 [0-3]: " sub_num
        case "${sub_num}" in
            1)
                journalctl -u realm -f
                ;;
            2)
                echo -e "${BLUE}============== 最近 50 条日志 ==============${PLAIN}"
                journalctl -u realm -n 50 --no-pager
                echo -e "${BLUE}============================================${PLAIN}"
                ;;
            3)
                echo -e "${BLUE}============== 最近 100 条日志 =============${PLAIN}"
                journalctl -u realm -n 100 --no-pager
                echo -e "${BLUE}============================================${PLAIN}"
                ;;
            0)
                break
                ;;
            *)
                error "无效选项！"
                ;;
        esac
    done
}

main_menu() {
    clear 2>/dev/null || true
    echo -e "${GREEN}=================================================${PLAIN}"
    echo -e "${GREEN}        Realm 高性能 TCP 端口中转管理脚本        ${PLAIN}"
    echo -e "${GREEN}        项目: https://github.com/Gaoshou101/realm-relay  ${PLAIN}"
    echo -e "${GREEN}=================================================${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 运行状态概览"
    echo -e "  ${GREEN}2.${PLAIN} 转发规则管理 (查看 / 添加 / 修改 / 删除)"
    echo -e "  ${GREEN}3.${PLAIN} 服务运维控制 (启动 / 停止 / 重启 / 自启)"
    echo -e "  ${GREEN}4.${PLAIN} 日志与排错 (实时追踪 / 历史日志)"
    echo -e "  ${GREEN}5.${PLAIN} 安装 / 重装 Realm"
    echo -e "  ${GREEN}6.${PLAIN} 彻底卸载 Realm"
    echo -e "  ${GREEN}0.${PLAIN} 退出脚本"
    echo -e "${GREEN}=================================================${PLAIN}"

    local total
    total="$(get_rules_count)"
    local st
    if systemctl is-active realm >/dev/null 2>&1; then
        st="${GREEN}运行中${PLAIN}"
    else
        st="${RED}已停止${PLAIN}"
    fi
    echo -e "服务状态: [${st}]   当前生效规则数: ${YELLOW}${total}${PLAIN} 条"
    echo -e "${GREEN}=================================================${PLAIN}"

    read -r -p "请输入主菜单选项 [0-6]: " num
    case "${num}" in
        1)
            show_status
            ;;
        2)
            menu_rules
            ;;
        3)
            menu_service
            ;;
        4)
            menu_logs
            ;;
        5)
            install_realm
            ;;
        6)
            uninstall_realm
            ;;
        0)
            exit 0
            ;;
        *)
            error "请输入有效选项！"
            ;;
    esac
}

# 命令行直接快捷参数
action="${1:-}"
case "${action}" in
    install)
        install_realm
        ;;
    status)
        show_status
        ;;
    add)
        add_rule
        ;;
    del)
        del_rule
        ;;
    list)
        list_rules_table
        ;;
    log|logs)
        journalctl -u realm -f
        ;;
    restart)
        systemctl restart realm
        ;;
    stop)
        systemctl stop realm
        ;;
    start)
        systemctl start realm
        ;;
    uninstall)
        uninstall_realm
        ;;
    *)
        while true; do
            main_menu
            echo
            read -r -p "按回车键返回主菜单 (或 Ctrl+C 退出)..." _
        done
        ;;
esac
