#!/bin/bash
# ============================================================
#  Gemini Business2API 一键部署脚本 v3
#  针对 OpenCloudOS 9 深度优化，全自动无交互
#  适用系统: OpenCloudOS 9 / RHEL 9 / CentOS 9 / Rocky 9
# ============================================================

set -euo pipefail

SCRIPT_VERSION="3.0"
LOG_FILE="/var/log/gemini-b2api-deploy.log"
INSTALL_DIR="/opt/gemini-business2api"
SERVICE_NAME="gemini-b2api"
REPO_URL="https://github.com/Dreamy-rain/gemini-business2api.git"
AUTO_REG_REPO="https://github.com/zorazeroyzz/gemini-api-deploy.git"
PORT=7860
ADMIN_KEY=""
PYTHON_CMD=""

# Clash/mihomo
CLASH_INSTALL_DIR="/opt/mihomo"
CLASH_SERVICE_NAME="mihomo"
CLASH_HTTP_PORT=7890
CLASH_SOCKS_PORT=7891
CLASH_API_PORT=9090
CLASH_SUB_URL=""

# GitHub 镜像（国内加速）
GHPROXY="https://ghfast.top"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# ─────────────────────── 日志 ───────────────────────

_log() {
    local level="$1" icon="$2" msg="$3"
    local ts; ts=$(date '+%H:%M:%S')
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

die() { log_error "$1"; exit 1; }

cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        log_error "部署出错 (退出码: ${exit_code})"
        log_error "详细日志: ${LOG_FILE}"
        echo -e "${YELLOW}排查: tail -50 ${LOG_FILE}${NC}"
    fi
}
trap cleanup EXIT

# ─────────────────────── 工具函数 ───────────────────────

generate_key() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32; }

retry() {
    local max=$1 delay=$2 desc="$3"; shift 3
    local attempt=1
    while [ $attempt -le $max ]; do
        if "$@" >> "${LOG_FILE}" 2>&1; then return 0; fi
        log_warn "${desc}: 第 ${attempt}/${max} 次失败，${delay}s 后重试..."
        sleep "$delay"; attempt=$((attempt + 1))
    done
    return 1
}

# GitHub 克隆（自动尝试镜像）
git_clone_smart() {
    local repo="$1" dest="$2"
    log_step "克隆 ${repo}..."
    if git clone --depth 1 "${GHPROXY}/${repo}" "$dest" >> "${LOG_FILE}" 2>&1; then
        log_info "通过镜像克隆成功"
        return 0
    fi
    log_warn "镜像失败，尝试直连..."
    if retry 2 10 "Git clone" git clone --depth 1 "$repo" "$dest"; then
        return 0
    fi
    return 1
}

check_port() {
    ! ss -tlnp 2>/dev/null | grep -q ":${1} "
}

find_free_display() {
    local d=99
    while [ -e "/tmp/.X11-unix/X${d}" ] || [ -e "/tmp/.X${d}-lock" ]; do d=$((d+1)); done
    echo "$d"
}

# ─────────────────────── 参数解析 ───────────────────────

usage() {
    echo "用法: sudo bash deploy.sh [选项]"
    echo ""
    echo "选项:"
    echo "  --port PORT          服务端口 (默认: 7860)"
    echo "  --admin-key KEY      管理员密钥 (默认: 自动生成)"
    echo "  --install-dir DIR    安装目录 (默认: /opt/gemini-business2api)"
    echo "  --clash-sub URL      Clash 订阅地址 (留空跳过代理)"
    echo "  --clash-port PORT    Clash HTTP 代理端口 (默认: 7890)"
    echo "  --ghproxy URL        GitHub 镜像地址 (默认: https://ghfast.top)"
    echo "  --skip-clash         跳过代理部署"
    echo "  --skip-register      跳过自动注册脚本"
    echo "  -h, --help           显示帮助"
    exit 0
}

SKIP_CLASH=false
SKIP_REGISTER=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --port)         PORT="$2"; shift 2 ;;
        --admin-key)    ADMIN_KEY="$2"; shift 2 ;;
        --install-dir)  INSTALL_DIR="$2"; shift 2 ;;
        --clash-sub)    CLASH_SUB_URL="$2"; shift 2 ;;
        --clash-port)   CLASH_HTTP_PORT="$2"; shift 2 ;;
        --ghproxy)      GHPROXY="$2"; shift 2 ;;
        --skip-clash)   SKIP_CLASH=true; shift ;;
        --skip-register) SKIP_REGISTER=true; shift ;;
        -h|--help)      usage ;;
        *)              log_warn "未知参数: $1"; shift ;;
    esac
done

[ -z "$ADMIN_KEY" ] && ADMIN_KEY=$(generate_key)

# ─────────────────────── 环境预检 ───────────────────────

preflight() {
    log_step "环境预检..."

    [ "$EUID" -ne 0 ] && die "请使用 root 运行"

    source /etc/os-release 2>/dev/null || die "无法检测系统"
    log_info "系统: ${PRETTY_NAME}"

    command -v dnf &>/dev/null || die "仅支持 dnf 系统"

    local arch; arch=$(uname -m)
    [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]] && die "不支持: ${arch}"
    log_info "架构: ${arch}"

    local mem_avail; mem_avail=$(($(grep MemAvailable /proc/meminfo | awk '{print $2}') / 1024))
    [ $mem_avail -lt 512 ] && die "内存不足: ${mem_avail}MB (需要 512MB+)"
    log_info "内存: ${mem_avail}MB 可用"

    local disk_avail; disk_avail=$(($(df -k "${INSTALL_DIR%/*}" 2>/dev/null | tail -1 | awk '{print $4}') / 1024))
    [ $disk_avail -lt 2048 ] && die "磁盘不足: ${disk_avail}MB (需要 2GB+)"
    log_info "磁盘: ${disk_avail}MB 可用"

    # 自动创建 swap（内存 < 2GB 且无 swap）
    local swap_total; swap_total=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    if [ "$swap_total" -eq 0 ] && [ "$mem_avail" -lt 2048 ]; then
        if [ ! -f /swapfile ]; then
            log_step "创建 2GB swap..."
            dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress 2>>"${LOG_FILE}"
            chmod 600 /swapfile && mkswap /swapfile >> "${LOG_FILE}" 2>&1 && swapon /swapfile
            grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            log_info "swap 已创建"
        fi
    fi

    if ! check_port "$PORT"; then
        die "端口 ${PORT} 已被占用，使用 --port 指定其他端口"
    fi

    log_info "预检通过"
}

# ─────────────────────── 安装依赖 ───────────────────────

install_deps() {
    log_step "安装系统依赖..."

    # EPEL（OpenCloudOS 有 EPOL，不需要 epel-release）
    dnf install -y epel-release >> "${LOG_FILE}" 2>&1 || true

    # 基础工具
    retry 3 5 "基础工具" dnf install -y \
        git curl wget tar gcc make which tzdata unzip gzip \
        || die "基础工具安装失败"

    # Python 3.11 + pip
    log_step "安装 Python..."
    if ! command -v python3.11 &>/dev/null; then
        dnf install -y python3.11 python3.11-pip python3.11-devel >> "${LOG_FILE}" 2>&1 || \
        dnf install -y python3 python3-pip python3-devel >> "${LOG_FILE}" 2>&1 || \
            die "Python 安装失败"
    fi

    PYTHON_CMD=$(command -v python3.11 2>/dev/null || command -v python3)
    log_info "Python: $($PYTHON_CMD --version 2>&1)"

    # 确保 pip 可用（OpenCloudOS 默认不装 pip）
    if ! $PYTHON_CMD -m pip --version &>/dev/null; then
        log_step "安装 pip..."
        dnf install -y python3.11-pip python3-pip >> "${LOG_FILE}" 2>&1 || \
        $PYTHON_CMD -m ensurepip >> "${LOG_FILE}" 2>&1 || \
            die "pip 安装失败"
    fi
    log_info "pip: $($PYTHON_CMD -m pip --version 2>&1 | head -1)"

    # 浏览器：优先 google-chrome（OpenCloudOS 仓库没有 chromium）
    log_step "安装浏览器..."
    if command -v google-chrome-stable &>/dev/null || command -v chromium-browser &>/dev/null || command -v chromium &>/dev/null; then
        local browser_bin
        browser_bin=$(command -v google-chrome-stable 2>/dev/null || command -v chromium-browser 2>/dev/null || command -v chromium 2>/dev/null)
        log_info "浏览器已存在: $(${browser_bin} --version 2>/dev/null | head -1)"
    else
        # OpenCloudOS/RHEL 9 没有 chromium 包，直接装 Google Chrome
        if ! rpm -q google-chrome-stable &>/dev/null; then
            cat > /etc/yum.repos.d/google-chrome.repo <<'CHROMEREPO'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
CHROMEREPO
            retry 3 10 "Google Chrome" dnf install -y google-chrome-stable || {
                # 回退尝试 chromium
                rm -f /etc/yum.repos.d/google-chrome.repo
                dnf install -y chromium >> "${LOG_FILE}" 2>&1 || \
                    die "浏览器安装失败（chromium 和 google-chrome 均不可用）"
            }
        fi
        log_info "浏览器: $(google-chrome-stable --version 2>/dev/null || chromium --version 2>/dev/null | head -1)"
    fi

    # Xvfb + X11 依赖
    log_step "安装 Xvfb..."
    local x11_pkgs=(
        xorg-x11-server-Xvfb xorg-x11-xauth dbus-x11 mesa-libgbm
        libXcomposite libXdamage libXrandr libXfixes at-spi2-atk
        cups-libs libdrm libxkbcommon nss nspr atk pango cairo alsa-lib
    )
    for pkg in "${x11_pkgs[@]}"; do
        rpm -q "$pkg" &>/dev/null || dnf install -y "$pkg" >> "${LOG_FILE}" 2>&1 || true
    done
    command -v Xvfb &>/dev/null || die "Xvfb 安装失败"

    # 中文字体
    dnf install -y google-noto-cjk-fonts liberation-fonts >> "${LOG_FILE}" 2>&1 || \
    dnf install -y google-noto-sans-cjk-ttc-fonts >> "${LOG_FILE}" 2>&1 || true

    log_info "系统依赖安装完成"
}

# ─────────────────────── 部署代理 ───────────────────────

deploy_clash() {
    if [ "$SKIP_CLASH" = true ] || [ -z "${CLASH_SUB_URL}" ]; then
        log_info "跳过代理部署"
        return 0
    fi

    log_step "部署 mihomo 代理..."
    mkdir -p "${CLASH_INSTALL_DIR}/profiles"

    # 下载 mihomo
    if [ ! -f "${CLASH_INSTALL_DIR}/mihomo" ]; then
        local arch; arch=$(uname -m)
        local mihomo_arch="amd64"
        [ "$arch" = "aarch64" ] && mihomo_arch="arm64"

        local latest=""
        latest=$(curl -sf --max-time 15 "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" \
            | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' 2>/dev/null) || true
        [ -z "$latest" ] && latest="v1.19.0"
        log_info "mihomo 版本: ${latest}"

        local downloaded=false
        for base_url in "${GHPROXY}/https://github.com" "https://github.com"; do
            local url="${base_url}/MetaCubeX/mihomo/releases/download/${latest}/mihomo-linux-${mihomo_arch}-${latest}.gz"
            if wget -q --timeout=60 -O "${CLASH_INSTALL_DIR}/mihomo.gz" "$url" 2>>"${LOG_FILE}"; then
                downloaded=true; break
            fi
        done
        $downloaded || die "mihomo 下载失败"

        gzip -d "${CLASH_INSTALL_DIR}/mihomo.gz"
        chmod +x "${CLASH_INSTALL_DIR}/mihomo"
        log_info "mihomo: $(${CLASH_INSTALL_DIR}/mihomo -v 2>&1 | head -1)"
    fi

    # 下载 GeoIP 数据（国内镜像，避免启动时卡住）
    log_step "下载 GeoIP 数据..."
    for f in geoip.metadb geosite.dat country.mmdb; do
        if [ ! -f "${CLASH_INSTALL_DIR}/${f}" ]; then
            wget -q --timeout=30 -O "${CLASH_INSTALL_DIR}/${f}" \
                "${GHPROXY}/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/${f}" 2>>"${LOG_FILE}" || \
                log_warn "${f} 下载失败（不影响基本功能）"
        fi
    done

    # 下载并解析订阅
    log_step "下载订阅配置..."
    curl -fsSL --max-time 30 -o "${CLASH_INSTALL_DIR}/config_sub.raw" "${CLASH_SUB_URL}" 2>>"${LOG_FILE}" || \
        die "订阅下载失败"

    # 判断订阅格式并生成配置
    if head -1 "${CLASH_INSTALL_DIR}/config_sub.raw" | grep -qE '^(proxies:|port:|mixed-port:)'; then
        # 已经是 YAML 格式
        cp "${CLASH_INSTALL_DIR}/config_sub.raw" "${CLASH_INSTALL_DIR}/config.yaml"
        sed -i "s/^mixed-port:.*/mixed-port: ${CLASH_HTTP_PORT}/" "${CLASH_INSTALL_DIR}/config.yaml"
        sed -i "s/^port:.*/port: ${CLASH_HTTP_PORT}/" "${CLASH_INSTALL_DIR}/config.yaml"
        sed -i "s/^socks-port:.*/socks-port: ${CLASH_SOCKS_PORT}/" "${CLASH_INSTALL_DIR}/config.yaml"
        log_info "使用 YAML 订阅配置"
    else
        # Base64 编码的节点列表，用 Python 转换
        log_step "解析 Base64 订阅..."
        $PYTHON_CMD << 'PYSCRIPT'
import base64, urllib.parse, yaml, sys

try:
    with open('/opt/mihomo/config_sub.raw', 'r') as f:
        raw = f.read().strip()
    decoded = base64.b64decode(raw).decode('utf-8')
except Exception as e:
    print(f"解码失败: {e}", file=sys.stderr)
    sys.exit(1)

lines = [l.strip() for l in decoded.strip().split('\n') if l.strip()]
proxies, names = [], []

for line in lines:
    if line.startswith('trojan://'):
        rest = line[len('trojan://'):]
        name_part = rest.split('#', 1)
        name = urllib.parse.unquote(name_part[1]) if len(name_part) > 1 else 'unknown'
        main = name_part[0]
        cred_host = main.split('?', 1)
        params_str = cred_host[1] if len(cred_host) > 1 else ''
        cred = cred_host[0]
        pwd, hostport = cred.rsplit('@', 1)
        host, port = hostport.rsplit(':', 1)
        params = dict(urllib.parse.parse_qsl(params_str))
        sni = params.get('sni', '')
        skip = any(k in name for k in ['剩余', '到期', '重置', '官网', 'Telegram', '购买', '浏览'])
        if skip:
            continue
        proxies.append({
            'name': name, 'type': 'trojan', 'server': host, 'port': int(port),
            'password': pwd, 'sni': sni or host,
            'skip-cert-verify': params.get('allowInsecure', '0') == '1', 'udp': True
        })
        names.append(name)
    elif line.startswith('vless://'):
        rest = line[len('vless://'):]
        name_part = rest.split('#', 1)
        name = urllib.parse.unquote(name_part[1]) if len(name_part) > 1 else 'unknown'
        main = name_part[0]
        cred_host = main.split('?', 1)
        params_str = cred_host[1] if len(cred_host) > 1 else ''
        cred = cred_host[0]
        uuid, hostport = cred.rsplit('@', 1)
        host, port = hostport.rsplit(':', 1)
        params = dict(urllib.parse.parse_qsl(params_str))
        skip = any(k in name for k in ['剩余', '到期', '重置', '官网', 'Telegram', '购买', '浏览'])
        if skip:
            continue
        proxies.append({
            'name': name, 'type': 'vless', 'server': host, 'port': int(port),
            'uuid': uuid, 'tls': params.get('security', '') == 'tls',
            'flow': params.get('flow', ''), 'network': params.get('type', 'tcp'),
            'udp': True, 'skip-cert-verify': False, 'servername': host
        })
        names.append(name)

if not proxies:
    print("未解析到有效节点", file=sys.stderr)
    sys.exit(1)

CLASH_HTTP_PORT = CLASH_SOCKS_PORT = 0
import os
CLASH_HTTP_PORT = int(os.environ.get('CLASH_HTTP_PORT', 7890))
CLASH_SOCKS_PORT = int(os.environ.get('CLASH_SOCKS_PORT', 7891))

config = {
    'mixed-port': CLASH_HTTP_PORT, 'socks-port': CLASH_SOCKS_PORT,
    'allow-lan': False, 'mode': 'rule', 'log-level': 'warning',
    'external-controller': '127.0.0.1:9090',
    'proxies': proxies,
    'proxy-groups': [
        {'name': 'PROXY', 'type': 'url-test', 'proxies': names,
         'url': 'http://www.gstatic.com/generate_204', 'interval': 300, 'tolerance': 100},
        {'name': 'DIRECT-GROUP', 'type': 'select', 'proxies': ['DIRECT']}
    ],
    'rules': [
        'DOMAIN-SUFFIX,google.com,PROXY', 'DOMAIN-SUFFIX,googleapis.com,PROXY',
        'DOMAIN-SUFFIX,gstatic.com,PROXY', 'DOMAIN-SUFFIX,gemini.google.com,PROXY',
        'DOMAIN-SUFFIX,duckmail.sbs,DIRECT-GROUP',
        'DOMAIN-KEYWORD,google,PROXY', 'DOMAIN-KEYWORD,gemini,PROXY',
        'GEOIP,CN,DIRECT-GROUP', 'MATCH,PROXY'
    ]
}

with open('/opt/mihomo/config.yaml', 'w') as f:
    yaml.dump(config, f, allow_unicode=True, default_flow_style=False)

print(f"配置已生成: {len(proxies)} 个有效节点")
PYSCRIPT
    fi

    # systemd 服务
    cat > /etc/systemd/system/${CLASH_SERVICE_NAME}.service <<EOF
[Unit]
Description=Mihomo Proxy
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
    local ok=false
    for i in $(seq 1 12); do
        if curl -sf --max-time 10 -x "http://127.0.0.1:${CLASH_HTTP_PORT}" \
            "https://www.gstatic.com/generate_204" >/dev/null 2>&1; then
            ok=true; break
        fi
        sleep 3
    done
    $ok && log_info "代理验证成功" || log_warn "代理未能在 36s 内连通，请检查节点"
}

# ─────────────────────── 部署项目 ───────────────────────

deploy_project() {
    log_step "部署 gemini-business2api..."

    if [ -d "${INSTALL_DIR}/.git" ]; then
        log_warn "目录已存在，保留数据覆盖安装"
        systemctl stop ${SERVICE_NAME} 2>/dev/null || true
        # 备份数据
        [ -d "${INSTALL_DIR}/data" ] && cp -r "${INSTALL_DIR}/data" /tmp/gemini-b2api-data-bak
        [ -f "${INSTALL_DIR}/.env" ] && cp "${INSTALL_DIR}/.env" /tmp/gemini-b2api-env-bak
        rm -rf "${INSTALL_DIR}"
    fi

    if [ ! -d "${INSTALL_DIR}" ]; then
        git_clone_smart "${REPO_URL}" "${INSTALL_DIR}" || die "项目克隆失败"
    fi

    # 恢复备份
    [ -d /tmp/gemini-b2api-data-bak ] && { cp -r /tmp/gemini-b2api-data-bak "${INSTALL_DIR}/data"; rm -rf /tmp/gemini-b2api-data-bak; }
    [ -f /tmp/gemini-b2api-env-bak ] && { cp /tmp/gemini-b2api-env-bak "${INSTALL_DIR}/.env"; rm -f /tmp/gemini-b2api-env-bak; }

    cd "${INSTALL_DIR}"

    # Python 依赖
    log_step "安装 Python 依赖..."
    $PYTHON_CMD -m pip install --upgrade pip >> "${LOG_FILE}" 2>&1 || true
    retry 3 10 "pip install" $PYTHON_CMD -m pip install -r requirements.txt || die "Python 依赖安装失败"
    $PYTHON_CMD -c "import DrissionPage" >> "${LOG_FILE}" 2>&1 || die "DrissionPage 导入失败"
    log_info "Python 依赖安装完成"

    # 前端构建
    log_step "构建前端..."
    cd frontend
    retry 3 15 "npm install" npm install --silent || {
        rm -rf node_modules package-lock.json
        retry 2 15 "npm install (clean)" npm install || die "前端依赖安装失败"
    }

    npm run build >> "${LOG_FILE}" 2>&1 || \
    NODE_OPTIONS="--max-old-space-size=1536" npm run build >> "${LOG_FILE}" 2>&1 || \
        die "前端构建失败"
    cd ..

    # vite 配置输出到 ../static/ 而非 frontend/dist/
    if [ -d "static" ] && [ -f "static/index.html" ]; then
        log_info "前端构建完成 ($(du -sh static 2>/dev/null | cut -f1))"
    elif [ -d "frontend/dist" ]; then
        rm -rf static
        mv frontend/dist static
        log_info "前端构建完成"
    else
        die "前端构建产物不存在"
    fi

    # 配置
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
}

# ─────────────────────── 自动注册脚本 ───────────────────────

deploy_auto_register() {
    if [ "$SKIP_REGISTER" = true ]; then
        log_info "跳过自动注册脚本"
        return 0
    fi

    log_step "部署自动注册脚本..."
    local auto_reg_dir="${INSTALL_DIR}/auto-register"

    if [ -d "${auto_reg_dir}" ]; then
        cd "${auto_reg_dir}" && git pull >> "${LOG_FILE}" 2>&1 || true
        cd "${INSTALL_DIR}"
    else
        git_clone_smart "${AUTO_REG_REPO}" "${auto_reg_dir}" || \
            log_warn "自动注册脚本克隆失败（不影响主服务）"
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
}

# ─────────────────────── systemd 服务 ───────────────────────

setup_service() {
    log_step "配置 systemd 服务..."

    local display; display=$(find_free_display)
    log_info "DISPLAY=:${display}"

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

    # 主服务依赖
    local after="network.target ${SERVICE_NAME}-xvfb.service"
    local requires="${SERVICE_NAME}-xvfb.service"
    if [ -n "${CLASH_SUB_URL}" ] && [ "$SKIP_CLASH" != true ]; then
        after="${after} ${CLASH_SERVICE_NAME}.service"
        requires="${requires} ${CLASH_SERVICE_NAME}.service"
    fi

    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Gemini Business2API
After=${after}
Requires=${requires}
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
SyslogIdentifier=${SERVICE_NAME}
LimitNOFILE=65535
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}-xvfb ${SERVICE_NAME} >> "${LOG_FILE}" 2>&1
    log_info "服务配置完成"
}

# ─────────────────────── 防火墙 ───────────────────────

setup_firewall() {
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port=${PORT}/tcp >> "${LOG_FILE}" 2>&1 || true
        firewall-cmd --reload >> "${LOG_FILE}" 2>&1 || true
        log_info "防火墙已开放端口 ${PORT}"
    fi
}

# ─────────────────────── 启动并配置 ───────────────────────

start_and_configure() {
    log_step "启动服务..."

    systemctl stop ${SERVICE_NAME} ${SERVICE_NAME}-xvfb 2>/dev/null || true
    sleep 1
    systemctl start ${SERVICE_NAME}-xvfb || die "Xvfb 启动失败"
    sleep 2
    systemctl start ${SERVICE_NAME} || {
        journalctl -u ${SERVICE_NAME} --no-pager -n 20 2>/dev/null
        die "主服务启动失败"
    }

    # 等待就绪
    log_info "等待服务就绪..."
    local ready=false
    for i in $(seq 1 30); do
        if curl -sf "http://localhost:${PORT}/" >/dev/null 2>&1; then
            ready=true; break
        fi
        sleep 2
    done
    $ready && log_info "服务启动成功" || log_warn "服务在 60s 内未就绪，可能仍在启动"

    # 自动配置注册参数（使用 PUT 方法）
    log_step "配置注册参数..."
    local cookie_jar; cookie_jar=$(mktemp)

    # 登录
    local login_ok=false
    for attempt in 1 2 3; do
        if curl -sf -c "${cookie_jar}" -X POST "http://localhost:${PORT}/login" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "admin_key=${ADMIN_KEY}" 2>/dev/null | grep -q '"success"'; then
            login_ok=true; break
        fi
        sleep 2
    done

    if $login_ok; then
        # 获取当前设置，修改后 PUT 回去
        local current; current=$(curl -sf -b "${cookie_jar}" "http://localhost:${PORT}/admin/settings" 2>/dev/null)
        if [ -n "$current" ]; then
            local proxy_setting=""
            if [ -n "${CLASH_SUB_URL}" ] && [ "$SKIP_CLASH" != true ]; then
                proxy_setting="\"proxy_for_auth\": \"http://127.0.0.1:${CLASH_HTTP_PORT}\","
            fi

            echo "$current" | $PYTHON_CMD -c "
import sys, json
d = json.load(sys.stdin)
d['basic']['browser_headless'] = False
d['basic']['temp_mail_provider'] = 'duckmail'
d['basic']['register_domain'] = 'duckmail.sbs'
proxy = '${CLASH_SUB_URL}'
skip = '${SKIP_CLASH}'
if proxy and skip != 'true':
    d['basic']['proxy_for_auth'] = 'http://127.0.0.1:${CLASH_HTTP_PORT}'
print(json.dumps(d))
" | curl -sf -b "${cookie_jar}" -X PUT "http://localhost:${PORT}/admin/settings" \
                -H "Content-Type: application/json" -d @- >/dev/null 2>&1

            log_info "注册参数已配置 (headless=false, duckmail, duckmail.sbs)"
            [ -n "${CLASH_SUB_URL}" ] && [ "$SKIP_CLASH" != true ] && \
                log_info "代理已配置: http://127.0.0.1:${CLASH_HTTP_PORT}"
        fi
    else
        log_warn "自动登录失败，请手动在管理面板配置注册参数"
    fi
    rm -f "${cookie_jar}"
}

# ─────────────────────── 管理脚本 ───────────────────────

create_scripts() {
    log_step "创建管理脚本..."

    # 注册脚本
    cat > "${INSTALL_DIR}/register.sh" <<'REGEOF'
#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
COUNT=${1:-10}
PORT=$(grep PORT "${DIR}/.env" | cut -d= -f2)
PYTHON=$(command -v python3.11 2>/dev/null || command -v python3)

if [ -f "${DIR}/auto-register/config.json" ]; then
    echo "注册 ${COUNT} 个账号..."
    $PYTHON "${DIR}/auto-register/auto_register.py" -n "$COUNT" --config "${DIR}/auto-register/config.json"
else
    echo "错误: 自动注册脚本未部署"
    exit 1
fi
REGEOF
    chmod +x "${INSTALL_DIR}/register.sh"

    # 状态脚本
    cat > "${INSTALL_DIR}/status.sh" <<'STATEOF'
#!/bin/bash
echo ""
echo "═══════════════════════════════════════════"
echo "  Gemini Business2API 服务状态"
echo "═══════════════════════════════════════════"
echo ""
for svc in gemini-b2api-xvfb gemini-b2api mihomo; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
        st=$(systemctl is-active "$svc" 2>/dev/null || echo "不存在")
        printf "  %-25s %s\n" "${svc}:" "${st}"
    fi
done
echo ""
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=$(grep PORT "${DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "7860")
echo -n "  健康检查:  "
curl -sf "http://localhost:${PORT}/" >/dev/null 2>&1 && echo "OK" || echo "不可用"
if systemctl is-active mihomo &>/dev/null; then
    echo -n "  代理测试:  "
    curl -sf --max-time 5 -x http://127.0.0.1:7890 https://www.gstatic.com/generate_204 >/dev/null 2>&1 && echo "OK" || echo "不通"
fi
echo ""
STATEOF
    chmod +x "${INSTALL_DIR}/status.sh"

    # 卸载脚本
    cat > "${INSTALL_DIR}/uninstall.sh" <<'UNEOF'
#!/bin/bash
echo "确认卸载 Gemini Business2API? [y/N]"
read -r confirm
[[ ! "$confirm" =~ ^[Yy] ]] && exit 0
for svc in gemini-b2api gemini-b2api-xvfb mihomo; do
    systemctl stop "$svc" 2>/dev/null; systemctl disable "$svc" 2>/dev/null
    rm -f "/etc/systemd/system/${svc}.service"
done
systemctl daemon-reload
echo "服务已移除。文件保留在 /opt/gemini-business2api 和 /opt/mihomo"
echo "完全删除: rm -rf /opt/gemini-business2api /opt/mihomo"
UNEOF
    chmod +x "${INSTALL_DIR}/uninstall.sh"

    log_info "管理脚本已创建"
}

# ─────────────────────── 打印结果 ───────────────────────

print_result() {
    local ip
    ip=$(curl -sf --max-time 5 http://ipinfo.io/ip 2>/dev/null || \
         curl -sf --max-time 5 http://ifconfig.me 2>/dev/null || echo "YOUR_IP")

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  部署完成 v${SCRIPT_VERSION}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  管理面板:  http://${ip}:${PORT}"
    echo "  API 地址:  http://${ip}:${PORT}/v1/chat/completions"
    echo "  管理密钥:  ${ADMIN_KEY}"
    echo "  安装目录:  ${INSTALL_DIR}"
    echo ""
    if [ -n "${CLASH_SUB_URL}" ] && [ "$SKIP_CLASH" != true ]; then
        echo "  代理 HTTP:   http://127.0.0.1:${CLASH_HTTP_PORT}"
        echo "  代理 SOCKS5: socks5://127.0.0.1:${CLASH_SOCKS_PORT}"
        echo ""
    fi
    echo -e "${CYAN}  常用命令:${NC}"
    echo "  查看状态:  ${INSTALL_DIR}/status.sh"
    echo "  查看日志:  journalctl -u ${SERVICE_NAME} -f"
    echo "  重启服务:  systemctl restart ${SERVICE_NAME}"
    echo "  注册账号:  ${INSTALL_DIR}/register.sh 10"
    echo "  卸载:      ${INSTALL_DIR}/uninstall.sh"
    echo ""
    echo -e "${YELLOW}  注意: 云服务器请确认安全组已放行端口 ${PORT}${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    # 保存密钥到文件
    echo "${ADMIN_KEY}" > "${INSTALL_DIR}/.admin_key"
    chmod 600 "${INSTALL_DIR}/.admin_key"
}

# ─────────────────────── 主流程 ───────────────────────

main() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    echo "=== 部署开始: $(date) | v${SCRIPT_VERSION} ===" >> "${LOG_FILE}"

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Gemini Business2API 一键部署 v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}  全自动 · 无交互 · OpenCloudOS 优化${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  安装目录:  ${INSTALL_DIR}"
    echo "  服务端口:  ${PORT}"
    echo "  管理密钥:  ${ADMIN_KEY:0:8}..."
    echo "  代理:      ${CLASH_SUB_URL:+是}${CLASH_SUB_URL:-否}"
    echo ""

    preflight
    install_deps
    deploy_clash
    deploy_project
    deploy_auto_register
    setup_service
    setup_firewall
    create_scripts
    start_and_configure
    print_result
}

main "$@"
