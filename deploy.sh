#!/bin/bash
# ============================================================
#  Gemini Business2API 一键部署脚本 v2
#  适用系统: OpenCloudOS 9 / RHEL 9 / CentOS 9 / Rocky 9
#  功能: 环境预检 → 安装依赖 → 部署代理 → 部署服务 → 自动注册 → 诊断
# ============================================================

# ─────────────────────── 严格模式与全局变量 ───────────────────────

set -euo pipefail

SCRIPT_VERSION="2.0"
LOG_FILE="/var/log/gemini-b2api-deploy.log"
INSTALL_DIR="/opt/gemini-business2api"
SERVICE_NAME="gemini-b2api"
REPO_URL="https://github.com/Dreamy-rain/gemini-business2api.git"
AUTO_REG_REPO="https://github.com/zorazeroyzz/gemini-auto-register.git"
PORT=7860
ADMIN_KEY=""
PYTHON_CMD=""

# Clash
CLASH_INSTALL_DIR="/opt/mihomo"
CLASH_SERVICE_NAME="mihomo"
CLASH_HTTP_PORT=7890
CLASH_SOCKS_PORT=7891
CLASH_API_PORT=9090
CLASH_SUB_URL=""

# 部署进度（用于断点续跑）
STATE_FILE="/var/lib/gemini-b2api-deploy-state"
STEP_COMPLETED=()

# ─────────────────────── 颜色 ───────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# ─────────────────────── 日志系统 ───────────────────────

_log() {
    local level="$1" icon="$2" msg="$3"
    local ts
    ts=$(date '+%H:%M:%S')
    local color="${NC}"
    case "$level" in
        INFO)  color="${GREEN}" ;;
        WARN)  color="${YELLOW}" ;;
        ERROR) color="${RED}" ;;
        STEP)  color="${CYAN}" ;;
    esac
    echo -e "${color}[${ts}] ${icon} ${msg}${NC}"
    echo "[${ts}] [${level}] ${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

log_info()  { _log INFO  "✓" "$1"; }
log_warn()  { _log WARN  "⚠" "$1"; }
log_error() { _log ERROR "✗" "$1"; }
log_step()  { _log STEP  "→" "$1"; }

# ─────────────────────── 错误处理与清理 ───────────────────────

cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        log_error "部署过程中出错 (退出码: ${exit_code})"
        log_error "详细日志: ${LOG_FILE}"
        echo ""
        echo -e "${YELLOW}── 故障排查建议 ──${NC}"
        echo "  1. 查看完整日志:  cat ${LOG_FILE}"
        echo "  2. 查看最后 30 行: tail -30 ${LOG_FILE}"
        echo "  3. 重新运行脚本会从断点继续"
        if [ -f "${STATE_FILE}" ]; then
            echo "  4. 强制重新开始:  rm ${STATE_FILE} && bash deploy.sh"
        fi
        echo ""
    fi
}
trap cleanup EXIT

die() {
    log_error "$1"
    exit 1
}

# ─────────────────────── 断点续跑 ───────────────────────

load_state() {
    if [ -f "${STATE_FILE}" ]; then
        source "${STATE_FILE}"
        log_info "检测到上次部署进度，将从断点继续"
        log_info "已完成: ${STEP_COMPLETED[*]:-无}"
        log_info "如需重新开始，删除 ${STATE_FILE}"
        echo ""
    fi
}

save_state() {
    local step="$1"
    STEP_COMPLETED+=("${step}")
    {
        echo "STEP_COMPLETED=(${STEP_COMPLETED[*]})"
        echo "INSTALL_DIR=\"${INSTALL_DIR}\""
        echo "PORT=${PORT}"
        echo "ADMIN_KEY=\"${ADMIN_KEY}\""
        echo "PYTHON_CMD=\"${PYTHON_CMD}\""
        echo "CLASH_SUB_URL=\"${CLASH_SUB_URL}\""
        echo "CLASH_HTTP_PORT=${CLASH_HTTP_PORT}"
        echo "CLASH_SOCKS_PORT=${CLASH_SOCKS_PORT}"
    } > "${STATE_FILE}"
}

step_done() {
    local step="$1"
    for s in "${STEP_COMPLETED[@]}"; do
        [ "$s" = "$step" ] && return 0
    done
    return 1
}

# ─────────────────────── 工具函数 ───────────────────────

generate_key() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

retry() {
    local max_attempts=$1 delay=$2 desc="$3"
    shift 3
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if "$@" >> "${LOG_FILE}" 2>&1; then
            return 0
        fi
        log_warn "${desc}: 第 ${attempt}/${max_attempts} 次失败，${delay}s 后重试..."
        sleep "$delay"
        attempt=$((attempt + 1))
    done
    log_error "${desc}: ${max_attempts} 次尝试后仍然失败"
    return 1
}

check_port() {
    local port=$1
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
        return 1  # port in use
    fi
    return 0  # port free
}

find_free_display() {
    local display=99
    while [ $display -lt 200 ]; do
        if [ ! -e "/tmp/.X11-unix/X${display}" ] && [ ! -e "/tmp/.X${display}-lock" ]; then
            echo "$display"
            return 0
        fi
        display=$((display + 1))
    done
    echo "99"
}

# ─────────────────────── 环境预检 ───────────────────────

preflight_checks() {
    log_step "环境预检..."
    local errors=0

    # Root
    if [ "$EUID" -ne 0 ]; then
        die "请使用 root 用户运行此脚本 (当前: $(whoami))"
    fi

    # OS
    if [ ! -f /etc/os-release ]; then
        die "无法检测操作系统"
    fi
    source /etc/os-release
    log_info "系统: ${PRETTY_NAME}"

    if ! command -v dnf &>/dev/null; then
        die "仅支持 dnf 系统 (OpenCloudOS/RHEL/CentOS/Rocky 9)"
    fi

    # 架构
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]]; then
        die "不支持的 CPU 架构: ${arch} (仅支持 x86_64/aarch64)"
    fi
    log_info "架构: ${arch}"

    # 内存
    local mem_total_kb mem_total_mb
    mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_total_mb=$((mem_total_kb / 1024))
    local mem_avail_kb mem_avail_mb
    mem_avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    mem_avail_mb=$((mem_avail_kb / 1024))

    if [ $mem_avail_mb -lt 512 ]; then
        log_error "可用内存不足: ${mem_avail_mb}MB (最低需要 512MB)"
        log_warn "建议: 关闭不必要的服务或增加内存/swap"
        errors=$((errors + 1))
    elif [ $mem_avail_mb -lt 1024 ]; then
        log_warn "可用内存偏低: ${mem_avail_mb}MB (建议 1GB+)，npm build 可能需要 swap"
    fi
    log_info "内存: ${mem_total_mb}MB 总计, ${mem_avail_mb}MB 可用"

    # 磁盘
    local disk_avail_kb disk_avail_mb
    disk_avail_kb=$(df -k "${INSTALL_DIR%/*}" 2>/dev/null | tail -1 | awk '{print $4}')
    disk_avail_mb=$((disk_avail_kb / 1024))

    if [ $disk_avail_mb -lt 2048 ]; then
        log_error "磁盘空间不足: ${disk_avail_mb}MB 可用 (最低需要 2GB)"
        errors=$((errors + 1))
    elif [ $disk_avail_mb -lt 5120 ]; then
        log_warn "磁盘空间偏低: ${disk_avail_mb}MB 可用 (建议 5GB+)"
    fi
    log_info "磁盘: ${disk_avail_mb}MB 可用 (${INSTALL_DIR%/*})"

    # 网络
    if ! curl -sf --max-time 10 https://github.com >/dev/null 2>&1; then
        if ! curl -sf --max-time 10 https://gitee.com >/dev/null 2>&1; then
            log_error "无法访问外网 (github.com / gitee.com)"
            errors=$((errors + 1))
        else
            log_warn "无法直接访问 GitHub，但 Gitee 可达"
        fi
    fi
    log_info "网络: 外网连通"

    # 端口检查
    if ! check_port "$PORT"; then
        log_warn "端口 ${PORT} 已被占用"
        local pid
        pid=$(ss -tlnp 2>/dev/null | grep ":${PORT} " | grep -oP 'pid=\K\d+' | head -1)
        if [ -n "$pid" ]; then
            log_warn "占用进程: $(ps -p $pid -o comm= 2>/dev/null || echo 'unknown') (PID: $pid)"
        fi
        read -rp "是否使用其他端口? [输入新端口/n 退出]: " new_port
        if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -gt 0 ] && [ "$new_port" -lt 65536 ]; then
            PORT=$new_port
            log_info "已切换到端口 ${PORT}"
        elif [[ "$new_port" =~ ^[Nn] ]]; then
            die "端口冲突，退出"
        fi
    fi

    # swap 检查（npm build 可能需要）
    local swap_total_kb
    swap_total_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    if [ "$swap_total_kb" -eq 0 ] && [ "$mem_avail_mb" -lt 2048 ]; then
        log_warn "没有 swap 且内存 < 2GB，npm build 可能 OOM"
        read -rp "是否自动创建 2GB swap? [Y/n]: " create_swap
        if [[ ! "$create_swap" =~ ^[Nn] ]]; then
            create_swap_file
        fi
    fi

    if [ $errors -gt 0 ]; then
        die "预检发现 ${errors} 个阻塞问题，请修复后重试"
    fi

    log_info "预检通过"
}

create_swap_file() {
    local swap_file="/swapfile"
    if [ -f "$swap_file" ]; then
        log_info "swap 文件已存在"
        return 0
    fi
    log_step "创建 2GB swap..."
    dd if=/dev/zero of="$swap_file" bs=1M count=2048 status=progress 2>>"${LOG_FILE}"
    chmod 600 "$swap_file"
    mkswap "$swap_file" >> "${LOG_FILE}" 2>&1
    swapon "$swap_file"
    echo "$swap_file none swap sw 0 0" >> /etc/fstab
    log_info "swap 已创建并启用"
}

# ─────────────────────── 交互式配置 ───────────────────────

configure() {
    # 如果有断点数据，跳过配置
    if step_done "configure"; then
        log_info "使用上次的配置 (ADMIN_KEY=${ADMIN_KEY:0:8}...)"
        return 0
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Gemini Business2API 一键部署 v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo ""

    read -rp "安装目录 [${INSTALL_DIR}]: " input
    INSTALL_DIR="${input:-$INSTALL_DIR}"

    read -rp "服务端口 [${PORT}]: " input
    PORT="${input:-$PORT}"

    local default_key
    default_key=$(generate_key)
    read -rp "管理员密钥 (留空自动生成): " input
    ADMIN_KEY="${input:-$default_key}"

    echo ""
    echo -e "${CYAN}──────────── 代理配置 ────────────${NC}"
    read -rp "Clash 订阅地址 (留空跳过): " input
    CLASH_SUB_URL="${input}"
    if [ -n "${CLASH_SUB_URL}" ]; then
        read -rp "HTTP 代理端口 [${CLASH_HTTP_PORT}]: " input
        CLASH_HTTP_PORT="${input:-$CLASH_HTTP_PORT}"
        read -rp "SOCKS5 代理端口 [${CLASH_SOCKS_PORT}]: " input
        CLASH_SOCKS_PORT="${input:-$CLASH_SOCKS_PORT}"
    fi

    echo ""
    echo -e "${CYAN}──────────── 配置确认 ────────────${NC}"
    echo "  安装目录:    ${INSTALL_DIR}"
    echo "  服务端口:    ${PORT}"
    echo "  管理员密钥:  ${ADMIN_KEY:0:8}..."
    if [ -n "${CLASH_SUB_URL}" ]; then
        echo "  代理:        是 (HTTP=${CLASH_HTTP_PORT})"
    else
        echo "  代理:        否"
    fi
    echo -e "${CYAN}──────────────────────────────────${NC}"
    echo ""
    read -rp "确认开始? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn] ]] && { log_warn "已取消"; exit 0; }

    save_state "configure"
}

# ─────────────────────── 安装系统依赖 ───────────────────────

install_deps() {
    if step_done "deps"; then
        log_info "系统依赖已安装，跳过"
        # 恢复 PYTHON_CMD
        if [ -z "${PYTHON_CMD}" ]; then
            PYTHON_CMD=$(command -v python3.11 2>/dev/null || command -v python3)
        fi
        return 0
    fi

    log_step "安装系统依赖..."

    # EPEL
    log_step "启用 EPEL 仓库..."
    retry 3 5 "EPEL 安装" dnf install -y epel-release || true

    # 基础工具
    log_step "安装基础工具..."
    retry 3 5 "基础工具" dnf install -y \
        git curl wget tar gcc make which tzdata unzip gzip \
        || die "基础工具安装失败"

    # Python 3.11
    log_step "安装 Python 3.11..."
    if command -v python3.11 &>/dev/null; then
        log_info "Python 3.11 已存在"
    else
        dnf install -y python3.11 python3.11-pip python3.11-devel >> "${LOG_FILE}" 2>&1 || {
            log_warn "默认仓库未找到 python3.11，尝试安装 python3..."
            dnf install -y python3 python3-pip python3-devel >> "${LOG_FILE}" 2>&1 || \
                die "Python 安装失败"
        }
    fi

    if command -v python3.11 &>/dev/null; then
        PYTHON_CMD="python3.11"
    elif command -v python3 &>/dev/null; then
        PYTHON_CMD="python3"
    else
        die "找不到可用的 Python"
    fi

    local py_ver
    py_ver=$($PYTHON_CMD --version 2>&1)
    log_info "Python: ${py_ver}"

    # Python 版本检查
    local py_minor
    py_minor=$($PYTHON_CMD -c 'import sys; print(sys.version_info.minor)')
    if [ "$py_minor" -ge 12 ]; then
        log_warn "Python 3.12+ 检测到，部分依赖可能有兼容问题"
    fi

    # Chromium
    log_step "安装 Chromium..."
    if command -v chromium-browser &>/dev/null || command -v chromium &>/dev/null; then
        log_info "Chromium 已存在: $(command -v chromium-browser || command -v chromium)"
    else
        local chromium_installed=false
        for pkg in chromium "chromium chromium-headless" chromium-browser; do
            if dnf install -y $pkg >> "${LOG_FILE}" 2>&1; then
                chromium_installed=true
                break
            fi
        done
        if ! $chromium_installed; then
            die "无法安装 Chromium。日志: ${LOG_FILE}"
        fi
    fi

    # Chromium 可执行文件验证
    local chromium_bin
    chromium_bin=$(command -v chromium-browser 2>/dev/null || command -v chromium 2>/dev/null || echo "")
    if [ -z "$chromium_bin" ]; then
        die "Chromium 安装后找不到可执行文件"
    fi
    log_info "Chromium: $(${chromium_bin} --version 2>/dev/null | head -1 || echo 'installed')"

    # Xvfb 和 X11 依赖
    log_step "安装 Xvfb 和显示依赖..."
    local x11_pkgs=(
        xorg-x11-server-Xvfb xorg-x11-xauth dbus-x11 mesa-libgbm
        libXcomposite libXdamage libXrandr libXfixes at-spi2-atk
        cups-libs libdrm libxkbcommon nss nspr atk pango cairo alsa-lib
    )
    local failed_pkgs=()
    for pkg in "${x11_pkgs[@]}"; do
        if ! rpm -q "$pkg" &>/dev/null; then
            if ! dnf install -y "$pkg" >> "${LOG_FILE}" 2>&1; then
                failed_pkgs+=("$pkg")
            fi
        fi
    done
    if [ ${#failed_pkgs[@]} -gt 0 ]; then
        log_warn "以下 X11 包安装失败 (可能不影响运行): ${failed_pkgs[*]}"
    fi

    # 验证 Xvfb
    if ! command -v Xvfb &>/dev/null; then
        die "Xvfb 安装失败，这是必须的"
    fi

    # 中文字体
    log_step "安装中文字体..."
    dnf install -y google-noto-cjk-fonts liberation-fonts >> "${LOG_FILE}" 2>&1 || \
    dnf install -y google-noto-sans-cjk-ttc-fonts liberation-sans-fonts >> "${LOG_FILE}" 2>&1 || \
        log_warn "中文字体安装失败，注册页面可能显示异常"

    # Node.js
    if command -v node &>/dev/null; then
        log_info "Node: $(node --version)"
    else
        log_step "安装 Node.js..."
        dnf install -y nodejs npm >> "${LOG_FILE}" 2>&1 || {
            log_step "尝试 NodeSource 安装..."
            retry 2 5 "NodeSource" bash -c 'curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -'
            retry 2 5 "Node.js" dnf install -y nodejs || die "Node.js 安装失败"
        }
        log_info "Node: $(node --version)"
    fi

    log_info "系统依赖安装完成"
    save_state "deps"
}

# ─────────────────────── 部署 Clash ───────────────────────

deploy_clash() {
    if [ -z "${CLASH_SUB_URL}" ]; then
        log_info "跳过代理部署"
        return 0
    fi

    if step_done "clash"; then
        log_info "Clash 已部署，跳过"
        return 0
    fi

    log_step "部署 Clash 代理 (mihomo)..."
    mkdir -p "${CLASH_INSTALL_DIR}"

    # 端口冲突检查
    if ! check_port "$CLASH_HTTP_PORT"; then
        log_warn "Clash HTTP 端口 ${CLASH_HTTP_PORT} 已被占用"
        CLASH_HTTP_PORT=$((CLASH_HTTP_PORT + 10))
        log_info "自动切换到 ${CLASH_HTTP_PORT}"
    fi

    # 下载 mihomo
    if [ ! -f "${CLASH_INSTALL_DIR}/mihomo" ]; then
        log_step "下载 mihomo..."
        local arch
        arch=$(uname -m)
        local mihomo_arch="amd64"
        [ "$arch" = "aarch64" ] && mihomo_arch="arm64"

        # 尝试从 GitHub API 获取最新版本
        local latest_version=""
        latest_version=$(curl -sf --max-time 15 \
            "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" \
            | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' 2>/dev/null) || true

        if [ -z "$latest_version" ]; then
            latest_version="v1.19.0"
            log_warn "无法获取最新版本，使用 ${latest_version}"
        fi
        log_info "mihomo 版本: ${latest_version}"

        # 尝试多种 URL 格式
        local urls=(
            "https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/mihomo-linux-${mihomo_arch}-${latest_version}.gz"
            "https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/mihomo-linux-${mihomo_arch}.gz"
        )

        local downloaded=false
        for url in "${urls[@]}"; do
            log_info "尝试: ${url}"
            if wget -q --show-progress --timeout=60 -O "${CLASH_INSTALL_DIR}/mihomo.gz" "$url" 2>>"${LOG_FILE}"; then
                downloaded=true
                break
            fi
        done

        if ! $downloaded; then
            log_error "所有 mihomo 下载链接失败"
            log_warn "请手动下载 mihomo 到 ${CLASH_INSTALL_DIR}/mihomo"
            log_warn "跳过代理部署，继续安装主服务"
            CLASH_SUB_URL=""
            return 0
        fi

        gzip -d "${CLASH_INSTALL_DIR}/mihomo.gz" || die "mihomo 解压失败"
        chmod +x "${CLASH_INSTALL_DIR}/mihomo"

        # 验证二进制
        if ! "${CLASH_INSTALL_DIR}/mihomo" -v >> "${LOG_FILE}" 2>&1; then
            die "mihomo 二进制无法执行 (架构不匹配?)"
        fi
        log_info "mihomo 安装成功: $(${CLASH_INSTALL_DIR}/mihomo -v 2>&1 | head -1)"
    fi

    # 下载订阅
    log_step "下载订阅配置..."
    retry 3 5 "订阅下载" wget -q --timeout=30 -O "${CLASH_INSTALL_DIR}/config_sub.yaml" "${CLASH_SUB_URL}" || \
    retry 3 5 "订阅下载(curl)" curl -fsSL --max-time 30 -o "${CLASH_INSTALL_DIR}/config_sub.yaml" "${CLASH_SUB_URL}" || {
        log_error "订阅配置下载失败，跳过代理"
        CLASH_SUB_URL=""
        return 0
    }

    # 验证订阅文件不为空
    if [ ! -s "${CLASH_INSTALL_DIR}/config_sub.yaml" ]; then
        log_error "订阅配置文件为空，跳过代理"
        CLASH_SUB_URL=""
        return 0
    fi

    # 生成配置
    log_step "生成 mihomo 配置..."
    if grep -q "^proxies:" "${CLASH_INSTALL_DIR}/config_sub.yaml" 2>/dev/null || \
       grep -q "^proxy-providers:" "${CLASH_INSTALL_DIR}/config_sub.yaml" 2>/dev/null; then
        cp "${CLASH_INSTALL_DIR}/config_sub.yaml" "${CLASH_INSTALL_DIR}/config.yaml"
        # 修改端口（使用 python 处理 YAML 更安全，但 sed 足够用于顶层字段）
        sed -i "s/^port:.*/port: ${CLASH_HTTP_PORT}/" "${CLASH_INSTALL_DIR}/config.yaml" 2>/dev/null || true
        sed -i "s/^socks-port:.*/socks-port: ${CLASH_SOCKS_PORT}/" "${CLASH_INSTALL_DIR}/config.yaml" 2>/dev/null || true
        sed -i "s/^mixed-port:.*/mixed-port: ${CLASH_HTTP_PORT}/" "${CLASH_INSTALL_DIR}/config.yaml" 2>/dev/null || true
        grep -q "^allow-lan:" "${CLASH_INSTALL_DIR}/config.yaml" || \
            sed -i "1i allow-lan: false" "${CLASH_INSTALL_DIR}/config.yaml"
        grep -q "^external-controller:" "${CLASH_INSTALL_DIR}/config.yaml" || \
            sed -i "/^allow-lan:/a external-controller: 127.0.0.1:${CLASH_API_PORT}" "${CLASH_INSTALL_DIR}/config.yaml"
        log_info "使用订阅完整配置 (端口已调整)"
    else
        cat > "${CLASH_INSTALL_DIR}/config.yaml" <<EOF
mixed-port: ${CLASH_HTTP_PORT}
socks-port: ${CLASH_SOCKS_PORT}
allow-lan: false
mode: rule
log-level: warning
external-controller: 127.0.0.1:${CLASH_API_PORT}

proxy-providers:
  subscription:
    type: http
    url: "${CLASH_SUB_URL}"
    interval: 3600
    path: ./profiles/sub.yaml
    health-check:
      enable: true
      interval: 600
      url: http://www.gstatic.com/generate_204

proxy-groups:
  - name: PROXY
    type: url-test
    use:
      - subscription
    url: http://www.gstatic.com/generate_204
    interval: 300
  - name: DIRECT-GROUP
    type: select
    proxies:
      - DIRECT

rules:
  - DOMAIN-SUFFIX,google.com,PROXY
  - DOMAIN-SUFFIX,googleapis.com,PROXY
  - DOMAIN-SUFFIX,google.com.hk,PROXY
  - DOMAIN-SUFFIX,gstatic.com,PROXY
  - DOMAIN-SUFFIX,duckmail.sbs,DIRECT-GROUP
  - DOMAIN-KEYWORD,google,PROXY
  - DOMAIN-KEYWORD,gemini,PROXY
  - GEOIP,CN,DIRECT-GROUP
  - MATCH,PROXY
EOF
        mkdir -p "${CLASH_INSTALL_DIR}/profiles"
        log_info "已生成 proxy-provider 配置"
    fi

    # systemd 服务
    cat > /etc/systemd/system/${CLASH_SERVICE_NAME}.service <<EOF
[Unit]
Description=Mihomo (Clash Meta) Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${CLASH_INSTALL_DIR}
ExecStart=${CLASH_INSTALL_DIR}/mihomo -d ${CLASH_INSTALL_DIR}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${CLASH_SERVICE_NAME} >> "${LOG_FILE}" 2>&1
    systemctl restart ${CLASH_SERVICE_NAME}

    # 验证
    log_step "验证代理..."
    sleep 5
    local proxy_ok=false
    for i in $(seq 1 15); do
        if curl -sf --max-time 10 -x "http://127.0.0.1:${CLASH_HTTP_PORT}" \
            "https://www.gstatic.com/generate_204" >/dev/null 2>&1; then
            proxy_ok=true
            break
        fi
        sleep 2
    done

    if $proxy_ok; then
        log_info "代理验证成功"
    else
        log_warn "代理未能在 30s 内连通 (节点可能需要更长时间)"
        log_warn "查看日志: journalctl -u ${CLASH_SERVICE_NAME} --no-pager -n 20"
        # 不 die，允许继续
    fi

    save_state "clash"
}

# ─────────────────────── 部署项目 ───────────────────────

deploy_project() {
    if step_done "project"; then
        log_info "项目已部署，跳过"
        return 0
    fi

    log_step "部署 gemini-business2api..."

    # 处理已存在的安装
    if [ -d "${INSTALL_DIR}" ]; then
        log_warn "目录已存在: ${INSTALL_DIR}"
        read -rp "覆盖安装? (保留 data/ 和 .env) [Y/n]: " confirm
        if [[ ! "$confirm" =~ ^[Nn] ]]; then
            systemctl stop ${SERVICE_NAME} 2>/dev/null || true
            # 保留数据
            if [ -d "${INSTALL_DIR}/data" ]; then
                cp -r "${INSTALL_DIR}/data" /tmp/gemini-b2api-data-backup
                log_info "已备份 data/ 到 /tmp/"
            fi
            if [ -f "${INSTALL_DIR}/.env" ]; then
                cp "${INSTALL_DIR}/.env" /tmp/gemini-b2api-env-backup
            fi
            rm -rf "${INSTALL_DIR}"
        fi
    fi

    if [ ! -d "${INSTALL_DIR}" ]; then
        log_step "克隆仓库 (depth=1)..."
        retry 3 10 "Git clone" git clone --depth 1 "${REPO_URL}" "${INSTALL_DIR}" || \
            die "Git clone 失败。检查网络或 GitHub 是否可达"
    fi

    # 恢复备份数据
    if [ -d /tmp/gemini-b2api-data-backup ]; then
        cp -r /tmp/gemini-b2api-data-backup "${INSTALL_DIR}/data"
        rm -rf /tmp/gemini-b2api-data-backup
        log_info "已恢复 data/ 备份"
    fi
    if [ -f /tmp/gemini-b2api-env-backup ]; then
        cp /tmp/gemini-b2api-env-backup "${INSTALL_DIR}/.env"
        rm -f /tmp/gemini-b2api-env-backup
        log_info "已恢复 .env 备份"
    fi

    cd "${INSTALL_DIR}"

    # Python 依赖
    log_step "安装 Python 依赖..."
    ${PYTHON_CMD} -m pip install --upgrade pip >> "${LOG_FILE}" 2>&1 || true
    retry 3 10 "pip install" ${PYTHON_CMD} -m pip install -r requirements.txt || \
        die "Python 依赖安装失败。日志: ${LOG_FILE}"

    # 验证关键依赖
    if ! ${PYTHON_CMD} -c "import DrissionPage" >> "${LOG_FILE}" 2>&1; then
        die "DrissionPage 导入失败，浏览器自动化将无法工作"
    fi
    log_info "Python 依赖验证通过"

    # 前端构建
    log_step "构建前端..."
    cd frontend

    # npm install 重试
    retry 3 15 "npm install" npm install --silent || {
        log_warn "npm install 失败，尝试清理重装..."
        rm -rf node_modules package-lock.json
        retry 2 15 "npm install (clean)" npm install || \
            die "前端依赖安装失败"
    }

    # npm build
    if ! npm run build >> "${LOG_FILE}" 2>&1; then
        log_error "前端构建失败"
        log_warn "尝试增加 Node 内存限制重试..."
        if ! NODE_OPTIONS="--max-old-space-size=1536" npm run build >> "${LOG_FILE}" 2>&1; then
            die "前端构建失败，即使增加内存限制。日志: ${LOG_FILE}"
        fi
    fi
    cd ..

    # 移动构建产物
    if [ -d "frontend/dist" ]; then
        rm -rf static
        mv frontend/dist static
        log_info "前端构建完成 ($(du -sh static 2>/dev/null | cut -f1))"
    else
        die "前端构建产物不存在 (frontend/dist/)"
    fi

    # 数据目录与配置
    mkdir -p data

    if [ ! -f .env ]; then
        cat > .env <<EOF
ADMIN_KEY=${ADMIN_KEY}
PORT=${PORT}
EOF
        log_info "已生成 .env"
    else
        log_info "保留已有 .env"
    fi

    log_info "项目部署完成"
    save_state "project"
}

# ─────────────────────── 部署自动注册脚本 ───────────────────────

deploy_auto_register() {
    if step_done "autoreg"; then
        log_info "自动注册脚本已部署，跳过"
        return 0
    fi

    log_step "部署自动注册脚本..."
    local auto_reg_dir="${INSTALL_DIR}/auto-register"

    if [ -d "${auto_reg_dir}" ]; then
        cd "${auto_reg_dir}"
        git pull >> "${LOG_FILE}" 2>&1 || log_warn "git pull 失败，使用现有版本"
        cd "${INSTALL_DIR}"
    else
        retry 3 10 "Git clone auto-register" git clone --depth 1 "${AUTO_REG_REPO}" "${auto_reg_dir}" || \
            log_warn "自动注册脚本克隆失败，跳过 (不影响主服务)"
    fi

    if [ -d "${auto_reg_dir}" ]; then
        cat > "${auto_reg_dir}/config.json" <<EOF
{
    "host": "http://localhost:${PORT}",
    "admin_key": "${ADMIN_KEY}",
    "count": 10,
    "mail_provider": "duckmail",
    "domain": "duckmail.sbs",
    "poll_interval": 15,
    "verify_api": true,
    "verify_model": "gemini-2.5-flash",
    "verify_prompt": "Reply OK"
}
EOF
        log_info "自动注册脚本已部署"
    fi

    save_state "autoreg"
}

# ─────────────────────── systemd 服务 ───────────────────────

setup_service() {
    if step_done "service"; then
        log_info "服务已配置，跳过"
        return 0
    fi

    log_step "配置 systemd 服务..."

    # 找到空闲的 DISPLAY
    local display
    display=$(find_free_display)
    log_info "使用 DISPLAY=:${display}"

    # Xvfb
    cat > /etc/systemd/system/${SERVICE_NAME}-xvfb.service <<EOF
[Unit]
Description=Xvfb Display :${display} for Gemini B2API

[Service]
Type=simple
ExecStart=/usr/bin/Xvfb :${display} -screen 0 1280x800x24 -ac -nolisten tcp
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # 主服务
    local after_deps="network.target ${SERVICE_NAME}-xvfb.service"
    local requires_deps="${SERVICE_NAME}-xvfb.service"
    if [ -n "${CLASH_SUB_URL}" ]; then
        after_deps="${after_deps} ${CLASH_SERVICE_NAME}.service"
        requires_deps="${requires_deps} ${CLASH_SERVICE_NAME}.service"
    fi

    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Gemini Business2API
After=${after_deps}
Requires=${requires_deps}
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
Environment=DISPLAY=:${display}
Environment=PYTHONUNBUFFERED=1
Environment=TZ=Asia/Shanghai
EnvironmentFile=${INSTALL_DIR}/.env
ExecStartPre=/bin/sleep 2
ExecStart=${PYTHON_CMD} -u main.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}
LimitNOFILE=65535
TimeoutStopSec=30

# OOM 保护
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}-xvfb >> "${LOG_FILE}" 2>&1
    systemctl enable ${SERVICE_NAME} >> "${LOG_FILE}" 2>&1

    log_info "systemd 服务配置完成"
    save_state "service"
}

# ─────────────────────── 防火墙 ───────────────────────

setup_firewall() {
    log_step "配置防火墙..."
    if command -v firewall-cmd &>/dev/null; then
        if firewall-cmd --state &>/dev/null; then
            firewall-cmd --permanent --add-port=${PORT}/tcp >> "${LOG_FILE}" 2>&1 || true
            firewall-cmd --reload >> "${LOG_FILE}" 2>&1 || true
            log_info "防火墙已开放端口 ${PORT}"
        else
            log_info "firewalld 未运行，跳过"
        fi
    else
        log_info "未检测到 firewalld"
    fi
    log_warn "如使用云服务器，请确认安全组已放行端口 ${PORT}"
}

# ─────────────────────── 管理脚本 ───────────────────────

create_helper_scripts() {
    log_step "创建管理脚本..."

    # 注册脚本
    cat > "${INSTALL_DIR}/register.sh" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/auto-register/config.json"
COUNT=${1:-10}

if [ ! -f "$CONFIG" ]; then
    echo "错误: 配置文件不存在: $CONFIG"
    echo "请先运行部署脚本"
    exit 1
fi

# 检查主服务是否运行
if ! curl -sf http://localhost:$(grep PORT "${SCRIPT_DIR}/.env" | cut -d= -f2)/admin/health >/dev/null 2>&1; then
    echo "错误: 主服务未运行"
    echo "启动: systemctl start gemini-b2api"
    exit 1
fi

PYTHON_CMD=$(command -v python3.11 2>/dev/null || command -v python3)
echo "注册 ${COUNT} 个账号..."
$PYTHON_CMD "${SCRIPT_DIR}/auto-register/auto_register.py" -n "$COUNT" --config "$CONFIG"
SCRIPT
    chmod +x "${INSTALL_DIR}/register.sh"

    # 状态脚本
    cat > "${INSTALL_DIR}/status.sh" <<'STATUSEOF'
#!/bin/bash
echo ""
echo "═══════════════════════════════════════════"
echo "  Gemini Business2API 服务状态"
echo "═══════════════════════════════════════════"
echo ""

for svc in gemini-b2api-xvfb gemini-b2api mihomo; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null; then
        local_status=$(systemctl is-active "$svc" 2>/dev/null || echo "不存在")
        printf "  %-25s %s\n" "${svc}:" "${local_status}"
    fi
done

echo ""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=$(grep PORT "${SCRIPT_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "7860")

echo -n "  健康检查:  "
if curl -sf "http://localhost:${PORT}/admin/health" >/dev/null 2>&1; then
    echo "OK"
else
    echo "不可用"
fi

# 代理测试
if systemctl is-active mihomo &>/dev/null; then
    echo -n "  代理测试:  "
    if curl -sf --max-time 5 -x http://127.0.0.1:7890 https://www.gstatic.com/generate_204 >/dev/null 2>&1; then
        echo "OK"
    else
        echo "不通"
    fi
fi

echo ""
echo "  日志: journalctl -u gemini-b2api -f"
echo ""
STATUSEOF
    chmod +x "${INSTALL_DIR}/status.sh"

    # 卸载脚本
    cat > "${INSTALL_DIR}/uninstall.sh" <<'UNINSTEOF'
#!/bin/bash
echo "═══════════════════════════════════════════"
echo "  Gemini Business2API 卸载"
echo "═══════════════════════════════════════════"
echo ""
echo "将停止并移除以下服务:"
echo "  - gemini-b2api"
echo "  - gemini-b2api-xvfb"
echo "  - mihomo (如果存在)"
echo ""
read -rp "确认卸载? [y/N]: " confirm
[[ ! "$confirm" =~ ^[Yy] ]] && { echo "已取消"; exit 0; }

for svc in gemini-b2api gemini-b2api-xvfb mihomo; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
done
systemctl daemon-reload

rm -f /var/lib/gemini-b2api-deploy-state

echo ""
echo "服务已移除。文件保留在:"
echo "  /opt/gemini-business2api"
echo "  /opt/mihomo"
echo ""
echo "完全删除: rm -rf /opt/gemini-business2api /opt/mihomo"
UNINSTEOF
    chmod +x "${INSTALL_DIR}/uninstall.sh"

    # 订阅更新脚本
    if [ -n "${CLASH_SUB_URL}" ]; then
        cat > "${CLASH_INSTALL_DIR}/update-sub.sh" <<SUBEOF
#!/bin/bash
set -euo pipefail
echo "更新订阅..."
wget -q --timeout=30 -O "${CLASH_INSTALL_DIR}/config_sub_new.yaml" "${CLASH_SUB_URL}" || \
curl -fsSL --max-time 30 -o "${CLASH_INSTALL_DIR}/config_sub_new.yaml" "${CLASH_SUB_URL}" || \
    { echo "下载失败"; exit 1; }

if [ ! -s "${CLASH_INSTALL_DIR}/config_sub_new.yaml" ]; then
    echo "下载文件为空，保留旧配置"
    rm -f "${CLASH_INSTALL_DIR}/config_sub_new.yaml"
    exit 1
fi

mv "${CLASH_INSTALL_DIR}/config_sub_new.yaml" "${CLASH_INSTALL_DIR}/config_sub.yaml"

if grep -q "^proxies:" "${CLASH_INSTALL_DIR}/config_sub.yaml" 2>/dev/null || \
   grep -q "^proxy-providers:" "${CLASH_INSTALL_DIR}/config_sub.yaml" 2>/dev/null; then
    cp "${CLASH_INSTALL_DIR}/config_sub.yaml" "${CLASH_INSTALL_DIR}/config.yaml"
    sed -i "s/^port:.*/port: ${CLASH_HTTP_PORT}/" "${CLASH_INSTALL_DIR}/config.yaml" 2>/dev/null || true
    sed -i "s/^socks-port:.*/socks-port: ${CLASH_SOCKS_PORT}/" "${CLASH_INSTALL_DIR}/config.yaml" 2>/dev/null || true
    sed -i "s/^mixed-port:.*/mixed-port: ${CLASH_HTTP_PORT}/" "${CLASH_INSTALL_DIR}/config.yaml" 2>/dev/null || true
fi

systemctl restart mihomo
echo "订阅已更新，mihomo 已重启"
SUBEOF
        chmod +x "${CLASH_INSTALL_DIR}/update-sub.sh"
    fi

    log_info "管理脚本已创建"
}

# ─────────────────────── 启动服务 ───────────────────────

start_service() {
    log_step "启动服务..."

    # 确保旧进程停止
    systemctl stop ${SERVICE_NAME} 2>/dev/null || true
    systemctl stop ${SERVICE_NAME}-xvfb 2>/dev/null || true
    sleep 1

    systemctl start ${SERVICE_NAME}-xvfb || die "Xvfb 启动失败: journalctl -u ${SERVICE_NAME}-xvfb"
    sleep 2

    # 验证 Xvfb
    if ! systemctl is-active ${SERVICE_NAME}-xvfb &>/dev/null; then
        log_error "Xvfb 未能启动"
        journalctl -u ${SERVICE_NAME}-xvfb --no-pager -n 10 2>/dev/null
        die "请检查 Xvfb 日志"
    fi

    systemctl start ${SERVICE_NAME} || {
        log_error "主服务启动失败，查看日志:"
        journalctl -u ${SERVICE_NAME} --no-pager -n 20 2>/dev/null
        die "请修复后重试"
    }

    # 等待健康检查
    log_info "等待服务就绪..."
    local ready=false
    for i in $(seq 1 30); do
        if curl -sf "http://localhost:${PORT}/admin/health" >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 2
    done

    if $ready; then
        log_info "服务启动成功"
    else
        log_warn "服务在 60s 内未通过健康检查"
        log_warn "可能仍在启动中，请稍后运行: ${INSTALL_DIR}/status.sh"
        # 不 die，继续配置
    fi
}

# ─────────────────────── 配置注册参数 ───────────────────────

configure_register_settings() {
    log_step "配置自动注册参数..."

    # 确保服务可达
    if ! curl -sf "http://localhost:${PORT}/admin/health" >/dev/null 2>&1; then
        log_warn "服务尚未就绪，跳过自动配置"
        log_warn "请手动在管理面板中设置:"
        log_warn "  browser_headless = false"
        log_warn "  temp_mail_provider = duckmail"
        log_warn "  register_domain = duckmail.sbs"
        [ -n "${CLASH_SUB_URL}" ] && log_warn "  proxy_for_auth = http://127.0.0.1:${CLASH_HTTP_PORT}"
        return 0
    fi

    local cookie_jar
    cookie_jar=$(mktemp)

    # 登录 (带重试)
    local login_ok=false
    for attempt in 1 2 3; do
        local login_resp
        login_resp=$(curl -sf -c "${cookie_jar}" -X POST \
            "http://localhost:${PORT}/login" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "admin_key=${ADMIN_KEY}" 2>/dev/null) || true

        if echo "${login_resp}" | grep -q '"success"'; then
            login_ok=true
            break
        fi
        sleep 2
    done

    if ! $login_ok; then
        log_warn "自动登录失败，请手动在管理面板配置"
        rm -f "${cookie_jar}"
        return 0
    fi

    # 构建设置
    local settings_json
    if [ -n "${CLASH_SUB_URL}" ]; then
        settings_json="{
            \"browser_headless\": false,
            \"temp_mail_provider\": \"duckmail\",
            \"register_domain\": \"duckmail.sbs\",
            \"proxy_for_auth\": \"http://127.0.0.1:${CLASH_HTTP_PORT}\"
        }"
    else
        settings_json='{
            "browser_headless": false,
            "temp_mail_provider": "duckmail",
            "register_domain": "duckmail.sbs"
        }'
    fi

    local resp
    resp=$(curl -sf -b "${cookie_jar}" -X POST \
        "http://localhost:${PORT}/admin/settings" \
        -H "Content-Type: application/json" \
        -d "${settings_json}" 2>/dev/null) || true

    rm -f "${cookie_jar}"

    log_info "注册参数已配置:"
    log_info "  browser_headless = false"
    log_info "  temp_mail_provider = duckmail"
    log_info "  register_domain = duckmail.sbs"
    [ -n "${CLASH_SUB_URL}" ] && log_info "  proxy_for_auth = http://127.0.0.1:${CLASH_HTTP_PORT}"
}

# ─────────────────────── 部署后诊断 ───────────────────────

post_deploy_check() {
    log_step "部署后诊断..."
    local issues=0

    # 服务状态
    for svc in ${SERVICE_NAME}-xvfb ${SERVICE_NAME}; do
        if ! systemctl is-active "$svc" &>/dev/null; then
            log_warn "服务未运行: ${svc}"
            issues=$((issues + 1))
        fi
    done

    # 健康检查
    if ! curl -sf "http://localhost:${PORT}/admin/health" >/dev/null 2>&1; then
        log_warn "健康检查未通过"
        issues=$((issues + 1))
    fi

    # 代理
    if [ -n "${CLASH_SUB_URL}" ]; then
        if ! systemctl is-active ${CLASH_SERVICE_NAME} &>/dev/null; then
            log_warn "Clash 代理未运行"
            issues=$((issues + 1))
        fi
    fi

    # 磁盘使用
    local install_size
    install_size=$(du -sh "${INSTALL_DIR}" 2>/dev/null | cut -f1)
    log_info "安装大小: ${install_size}"

    if [ $issues -eq 0 ]; then
        log_info "诊断通过: 所有组件正常"
    else
        log_warn "诊断发现 ${issues} 个问题，请检查上方提示"
    fi
}

# ─────────────────────── 打印结果 ───────────────────────

print_result() {
    local public_ip
    public_ip=$(curl -sf --max-time 5 http://ipinfo.io/ip 2>/dev/null || \
                curl -sf --max-time 5 http://ifconfig.me 2>/dev/null || \
                echo "YOUR_SERVER_IP")

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  部署完成 (v${SCRIPT_VERSION})${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  管理面板:  http://${public_ip}:${PORT}"
    echo "  API 地址:  http://${public_ip}:${PORT}/v1/chat/completions"
    echo "  管理密钥:  ${ADMIN_KEY}"
    echo "  安装目录:  ${INSTALL_DIR}"
    echo "  部署日志:  ${LOG_FILE}"
    echo ""
    echo -e "${CYAN}  ── 注册参数 ──${NC}"
    echo "  headless:   false"
    echo "  邮箱:       duckmail / duckmail.sbs"
    [ -n "${CLASH_SUB_URL}" ] && echo "  代理:       http://127.0.0.1:${CLASH_HTTP_PORT}"
    echo ""
    if [ -n "${CLASH_SUB_URL}" ]; then
        echo -e "${CYAN}  ── Clash 代理 ──${NC}"
        echo "  HTTP:    http://127.0.0.1:${CLASH_HTTP_PORT}"
        echo "  SOCKS5:  socks5://127.0.0.1:${CLASH_SOCKS_PORT}"
        echo "  更新:    ${CLASH_INSTALL_DIR}/update-sub.sh"
        echo ""
    fi
    echo -e "${CYAN}  ── 常用命令 ──${NC}"
    echo "  查看状态:   ${INSTALL_DIR}/status.sh"
    echo "  查看日志:   journalctl -u ${SERVICE_NAME} -f"
    echo "  重启服务:   systemctl restart ${SERVICE_NAME}"
    echo "  注册账号:   ${INSTALL_DIR}/register.sh 10"
    echo "  卸载:       ${INSTALL_DIR}/uninstall.sh"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    # 清理部署状态文件
    rm -f "${STATE_FILE}"
}

# ─────────────────────── 主流程 ───────────────────────

main() {
    # 初始化日志
    mkdir -p "$(dirname "${LOG_FILE}")"
    echo "=== 部署开始: $(date) ===" >> "${LOG_FILE}"
    echo "=== 脚本版本: ${SCRIPT_VERSION} ===" >> "${LOG_FILE}"

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Gemini Business2API 一键部署 v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}  OpenCloudOS / RHEL / CentOS / Rocky 9${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo ""

    load_state
    preflight_checks
    configure
    install_deps
    deploy_clash
    deploy_project
    deploy_auto_register
    setup_service
    setup_firewall
    create_helper_scripts
    start_service
    configure_register_settings
    post_deploy_check
    print_result
}

main "$@"
