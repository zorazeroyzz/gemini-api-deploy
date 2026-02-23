#!/bin/bash
# ============================================================
#  Gemini Business2API 一键部署脚本
#  适用系统: OpenCloudOS 9 / RHEL 9 / CentOS 9 / Rocky 9
#  功能: 安装依赖 → 部署服务 → 配置自动注册 → 启动
# ============================================================

set -e

# ─────────────────────── 颜色定义 ───────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─────────────────────── 配置变量 ───────────────────────
INSTALL_DIR="/opt/gemini-business2api"
SERVICE_NAME="gemini-b2api"
REPO_URL="https://github.com/Dreamy-rain/gemini-business2api.git"
AUTO_REG_REPO="https://github.com/zorazeroyzz/gemini-auto-register.git"
PORT=7860
ADMIN_KEY=""

# ─────────────────────── 工具函数 ───────────────────────

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $1"; }

generate_key() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

check_os() {
    if [ ! -f /etc/os-release ]; then
        log_error "无法检测操作系统"
        exit 1
    fi
    source /etc/os-release
    log_info "检测到系统: $PRETTY_NAME"

    # 检查是否为 RHEL 系列
    if ! command -v dnf &>/dev/null; then
        log_error "此脚本仅支持使用 dnf 的系统 (OpenCloudOS/RHEL/CentOS/Rocky 9)"
        exit 1
    fi
}

# ─────────────────────── 交互式配置 ───────────────────────

configure() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Gemini Business2API 一键部署${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo ""

    # 安装目录
    read -rp "安装目录 [${INSTALL_DIR}]: " input
    INSTALL_DIR="${input:-$INSTALL_DIR}"

    # 端口
    read -rp "服务端口 [${PORT}]: " input
    PORT="${input:-$PORT}"

    # Admin Key
    DEFAULT_KEY=$(generate_key)
    read -rp "管理员密钥 (留空自动生成): " input
    ADMIN_KEY="${input:-$DEFAULT_KEY}"

    # 确认
    echo ""
    echo -e "${CYAN}──────────────── 配置确认 ────────────────${NC}"
    echo "  安装目录:   ${INSTALL_DIR}"
    echo "  服务端口:   ${PORT}"
    echo "  管理员密钥: ${ADMIN_KEY}"
    echo -e "${CYAN}──────────────────────────────────────────${NC}"
    echo ""
    read -rp "确认开始部署? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        log_warn "已取消"
        exit 0
    fi
}

# ─────────────────────── 安装系统依赖 ───────────────────────

install_deps() {
    log_step "安装系统依赖..."

    # 启用 EPEL（Chromium 等包可能需要）
    dnf install -y epel-release 2>/dev/null || true

    # 基础工具
    dnf install -y \
        git \
        curl \
        wget \
        tar \
        gcc \
        make \
        which \
        tzdata

    # Python 3.11
    log_step "安装 Python 3.11..."
    dnf install -y python3.11 python3.11-pip python3.11-devel 2>/dev/null || {
        # 如果默认仓库没有 3.11，尝试其他方式
        log_warn "默认仓库未找到 python3.11，尝试安装 python3..."
        dnf install -y python3 python3-pip python3-devel
    }

    # 确定 Python 命令
    if command -v python3.11 &>/dev/null; then
        PYTHON_CMD="python3.11"
    elif command -v python3 &>/dev/null; then
        PYTHON_CMD="python3"
    else
        log_error "Python 安装失败"
        exit 1
    fi
    log_info "Python: $($PYTHON_CMD --version)"

    # Chromium 浏览器
    log_step "安装 Chromium 浏览器..."
    dnf install -y chromium chromium-headless 2>/dev/null || {
        # OpenCloudOS 可能包名不同
        dnf install -y chromium-browser 2>/dev/null || {
            log_warn "dnf 安装 Chromium 失败，尝试 snap/flatpak..."
            # 最后手段：手动安装
            if ! command -v chromium-browser &>/dev/null && ! command -v chromium &>/dev/null; then
                log_error "无法安装 Chromium，请手动安装后重试"
                exit 1
            fi
        }
    }

    # Xvfb 和 X11 依赖
    log_step "安装 Xvfb 和显示依赖..."
    dnf install -y \
        xorg-x11-server-Xvfb \
        xorg-x11-xauth \
        dbus-x11 \
        mesa-libgbm \
        libXcomposite \
        libXdamage \
        libXrandr \
        libXfixes \
        at-spi2-atk \
        cups-libs \
        libdrm \
        libxkbcommon \
        nss \
        nspr \
        atk \
        pango \
        cairo \
        alsa-lib \
        2>/dev/null || true

    # 中文字体
    log_step "安装中文字体..."
    dnf install -y \
        google-noto-cjk-fonts \
        liberation-fonts \
        2>/dev/null || {
        dnf install -y \
            google-noto-sans-cjk-ttc-fonts \
            liberation-sans-fonts \
            2>/dev/null || true
    }

    # Node.js（系统可能已有）
    if ! command -v node &>/dev/null; then
        log_step "安装 Node.js..."
        dnf install -y nodejs npm 2>/dev/null || {
            curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
            dnf install -y nodejs
        }
    fi
    log_info "Node: $(node --version), NPM: $(npm --version)"

    log_info "系统依赖安装完成"
}

# ─────────────────────── 部署项目 ───────────────────────

deploy_project() {
    log_step "部署 gemini-business2api..."

    # 克隆项目
    if [ -d "${INSTALL_DIR}" ]; then
        log_warn "目录已存在: ${INSTALL_DIR}"
        read -rp "是否删除并重新部署? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy] ]]; then
            # 停止已有服务
            systemctl stop ${SERVICE_NAME} 2>/dev/null || true
            rm -rf "${INSTALL_DIR}"
        else
            log_info "保留现有安装，跳过克隆"
        fi
    fi

    if [ ! -d "${INSTALL_DIR}" ]; then
        git clone "${REPO_URL}" "${INSTALL_DIR}"
    fi

    cd "${INSTALL_DIR}"

    # 安装 Python 依赖
    log_step "安装 Python 依赖..."
    ${PYTHON_CMD} -m pip install --upgrade pip
    ${PYTHON_CMD} -m pip install -r requirements.txt

    # 构建前端
    log_step "构建前端..."
    cd frontend
    npm install --silent
    npm run build
    cd ..

    # 移动前端构建产物
    if [ -d "frontend/dist" ]; then
        rm -rf static
        mv frontend/dist static
        log_info "前端构建完成"
    fi

    # 创建数据目录
    mkdir -p data

    # 生成 .env 文件
    log_step "生成配置文件..."
    cat > .env <<EOF
# Gemini Business2API 配置
ADMIN_KEY=${ADMIN_KEY}
PORT=${PORT}
EOF

    log_info "项目部署完成"
}

# ─────────────────────── 部署自动注册脚本 ───────────────────────

deploy_auto_register() {
    log_step "部署自动注册脚本..."

    AUTO_REG_DIR="${INSTALL_DIR}/auto-register"

    if [ -d "${AUTO_REG_DIR}" ]; then
        cd "${AUTO_REG_DIR}" && git pull && cd ..
    else
        git clone "${AUTO_REG_REPO}" "${AUTO_REG_DIR}"
    fi

    # 生成自动注册配置
    cat > "${AUTO_REG_DIR}/config.json" <<EOF
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

    log_info "自动注册脚本已部署到: ${AUTO_REG_DIR}"
}

# ─────────────────────── 配置 systemd 服务 ───────────────────────

setup_service() {
    log_step "配置 systemd 服务..."

    # 确定 Chromium 路径
    CHROMIUM_PATH=$(which chromium-browser 2>/dev/null || which chromium 2>/dev/null || echo "/usr/bin/chromium-browser")

    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Gemini Business2API Service
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment=DISPLAY=:99
Environment=PYTHONUNBUFFERED=1
Environment=TZ=Asia/Shanghai
EnvironmentFile=${INSTALL_DIR}/.env

# 启动 Xvfb + 应用
ExecStartPre=/bin/bash -c 'pkill Xvfb || true'
ExecStartPre=/usr/bin/Xvfb :99 -screen 0 1280x800x24 -ac &
ExecStart=/bin/bash -c 'sleep 1 && exec ${PYTHON_CMD} -u main.py'

Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

# 资源限制
LimitNOFILE=65535
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

    # 创建 Xvfb 辅助服务
    cat > /etc/systemd/system/${SERVICE_NAME}-xvfb.service <<EOF
[Unit]
Description=Xvfb Virtual Display for Gemini B2API
Before=${SERVICE_NAME}.service

[Service]
Type=simple
ExecStart=/usr/bin/Xvfb :99 -screen 0 1280x800x24 -ac
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # 重新配置主服务使用 Xvfb 依赖
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Gemini Business2API Service
After=network.target ${SERVICE_NAME}-xvfb.service
Requires=${SERVICE_NAME}-xvfb.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment=DISPLAY=:99
Environment=PYTHONUNBUFFERED=1
Environment=TZ=Asia/Shanghai
EnvironmentFile=${INSTALL_DIR}/.env
ExecStartPre=/bin/sleep 2
ExecStart=${PYTHON_CMD} -u main.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}
LimitNOFILE=65535
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}-xvfb
    systemctl enable ${SERVICE_NAME}

    log_info "systemd 服务配置完成"
}

# ─────────────────────── 配置防火墙 ───────────────────────

setup_firewall() {
    log_step "配置防火墙..."

    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=${PORT}/tcp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        log_info "防火墙已开放端口 ${PORT}"
    else
        log_warn "未检测到 firewalld，跳过防火墙配置"
        log_warn "如使用云服务器，请在安全组中开放端口 ${PORT}"
    fi
}

# ─────────────────────── 创建管理脚本 ───────────────────────

create_helper_scripts() {
    log_step "创建管理脚本..."

    # 快捷注册脚本
    cat > "${INSTALL_DIR}/register.sh" <<'SCRIPT'
#!/bin/bash
# 快捷注册脚本
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/auto-register/config.json"

COUNT=${1:-10}

if [ ! -f "$CONFIG" ]; then
    echo "错误: 配置文件不存在: $CONFIG"
    exit 1
fi

PYTHON_CMD=$(which python3.11 2>/dev/null || which python3)
$PYTHON_CMD "${SCRIPT_DIR}/auto-register/auto_register.py" -n "$COUNT" --config "$CONFIG"
SCRIPT
    chmod +x "${INSTALL_DIR}/register.sh"

    # 状态查看脚本
    cat > "${INSTALL_DIR}/status.sh" <<SCRIPT
#!/bin/bash
echo ""
echo "═══════════════════════════════════════════"
echo "  Gemini Business2API 服务状态"
echo "═══════════════════════════════════════════"
echo ""
echo "--- Xvfb 服务 ---"
systemctl status ${SERVICE_NAME}-xvfb --no-pager -l 2>/dev/null | head -5
echo ""
echo "--- 主服务 ---"
systemctl status ${SERVICE_NAME} --no-pager -l 2>/dev/null | head -10
echo ""
echo "--- 健康检查 ---"
curl -sf http://localhost:${PORT}/admin/health 2>/dev/null && echo " OK" || echo "服务未响应"
echo ""
SCRIPT
    chmod +x "${INSTALL_DIR}/status.sh"

    # 卸载脚本
    cat > "${INSTALL_DIR}/uninstall.sh" <<SCRIPT
#!/bin/bash
echo "即将卸载 Gemini Business2API..."
read -rp "确认卸载? [y/N]: " confirm
if [[ ! "\$confirm" =~ ^[Yy] ]]; then
    echo "已取消"
    exit 0
fi
systemctl stop ${SERVICE_NAME} 2>/dev/null
systemctl stop ${SERVICE_NAME}-xvfb 2>/dev/null
systemctl disable ${SERVICE_NAME} 2>/dev/null
systemctl disable ${SERVICE_NAME}-xvfb 2>/dev/null
rm -f /etc/systemd/system/${SERVICE_NAME}.service
rm -f /etc/systemd/system/${SERVICE_NAME}-xvfb.service
systemctl daemon-reload
echo "服务已停止并移除"
echo "项目文件保留在: ${INSTALL_DIR}"
echo "如需完全删除，执行: rm -rf ${INSTALL_DIR}"
SCRIPT
    chmod +x "${INSTALL_DIR}/uninstall.sh"

    log_info "管理脚本已创建"
}

# ─────────────────────── 启动服务 ───────────────────────

start_service() {
    log_step "启动服务..."

    systemctl start ${SERVICE_NAME}-xvfb
    sleep 2
    systemctl start ${SERVICE_NAME}

    # 等待服务就绪
    log_info "等待服务启动..."
    for i in $(seq 1 30); do
        if curl -sf http://localhost:${PORT}/admin/health &>/dev/null; then
            log_info "服务启动成功"
            return 0
        fi
        sleep 2
    done

    log_warn "服务启动超时，请查看日志: journalctl -u ${SERVICE_NAME} -f"
    return 1
}

# ─────────────────────── 配置自动注册参数 ───────────────────────

configure_register_settings() {
    log_step "配置自动注册参数..."

    # 等待服务完全就绪
    sleep 3

    # 登录获取 session
    COOKIE_JAR=$(mktemp)
    LOGIN_RESP=$(curl -sf -c "${COOKIE_JAR}" -X POST \
        "http://localhost:${PORT}/login" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "admin_key=${ADMIN_KEY}" 2>/dev/null)

    if echo "${LOGIN_RESP}" | grep -q '"success"'; then
        # 获取当前设置
        SETTINGS=$(curl -sf -b "${COOKIE_JAR}" "http://localhost:${PORT}/admin/settings" 2>/dev/null)

        if [ -n "${SETTINGS}" ]; then
            # 更新关键设置: headless=false, duckmail, duckmail.sbs
            curl -sf -b "${COOKIE_JAR}" -X POST \
                "http://localhost:${PORT}/admin/settings" \
                -H "Content-Type: application/json" \
                -d '{
                    "browser_headless": false,
                    "temp_mail_provider": "duckmail",
                    "register_domain": "duckmail.sbs"
                }' >/dev/null 2>&1

            log_info "自动注册参数已配置 (headless=false, duckmail, duckmail.sbs)"
        else
            log_warn "无法获取当前设置，请手动在管理面板中配置:"
            log_warn "  browser_headless = false"
            log_warn "  temp_mail_provider = duckmail"
            log_warn "  domain = duckmail.sbs"
        fi
    else
        log_warn "自动登录失败，请手动在管理面板中配置自动注册参数"
    fi

    rm -f "${COOKIE_JAR}"
}

# ─────────────────────── 打印部署结果 ───────────────────────

print_result() {
    # 获取公网 IP
    PUBLIC_IP=$(curl -sf --max-time 5 http://ipinfo.io/ip 2>/dev/null || \
                curl -sf --max-time 5 http://ifconfig.me 2>/dev/null || \
                echo "YOUR_SERVER_IP")

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  部署完成${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  管理面板:  http://${PUBLIC_IP}:${PORT}"
    echo "  API 地址:  http://${PUBLIC_IP}:${PORT}/v1/chat/completions"
    echo "  管理密钥:  ${ADMIN_KEY}"
    echo "  安装目录:  ${INSTALL_DIR}"
    echo ""
    echo -e "${CYAN}  ── 关键配置（已自动设置） ──${NC}"
    echo "  browser_headless:   false  (防止 Google 检测)"
    echo "  temp_mail_provider: duckmail"
    echo "  domain:             duckmail.sbs"
    echo ""
    echo -e "${CYAN}  ── 常用命令 ──${NC}"
    echo "  查看状态:     ${INSTALL_DIR}/status.sh"
    echo "  查看日志:     journalctl -u ${SERVICE_NAME} -f"
    echo "  重启服务:     systemctl restart ${SERVICE_NAME}"
    echo "  停止服务:     systemctl stop ${SERVICE_NAME}"
    echo ""
    echo -e "${CYAN}  ── 自动注册 ──${NC}"
    echo "  注册 10 个:   ${INSTALL_DIR}/register.sh 10"
    echo "  注册  5 个:   ${INSTALL_DIR}/register.sh 5"
    echo "  自定义注册:   cd ${INSTALL_DIR}/auto-register"
    echo "                python3 auto_register.py -n 10 -k ${ADMIN_KEY}"
    echo ""
    echo -e "${CYAN}  ── 卸载 ──${NC}"
    echo "  卸载服务:     ${INSTALL_DIR}/uninstall.sh"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ─────────────────────── 主流程 ───────────────────────

main() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Gemini Business2API 一键部署${NC}"
    echo -e "${CYAN}  适用: OpenCloudOS / RHEL / CentOS / Rocky 9${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo ""

    check_root
    check_os
    configure
    install_deps
    deploy_project
    deploy_auto_register
    setup_service
    setup_firewall
    create_helper_scripts
    start_service
    configure_register_settings
    print_result
}

main "$@"
