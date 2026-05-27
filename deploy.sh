#!/bin/bash
# OpenHuman 生产级一键部署脚本 (aarch64, root, Nginx + systemd)
# 用法: curl -fsSL https://raw.githubusercontent.com/jinzechen/openhuman-deploy/main/deploy.sh | bash
# 可选环境变量:
#   FORCE_UPDATE_CORE=1  强制重新下载核心二进制
#   SKIP_BUILD=1         跳过前端构建（若已存在 dist 目录）

set -euo pipefail

# ===================== 配置 =====================
INSTALL_DIR="/opt/openhuman"
DATA_DIR="/var/lib/openhuman"
LOG_DIR="/var/log/openhuman"
CORE_BIN="$INSTALL_DIR/openhuman-core"
CORE_TOKEN_FILE="$DATA_DIR/core.token"
WEB_PORT=3000
RPC_PORT=7788
REPO_URL="https://github.com/tinyhumansai/openhuman.git"
GITHUB_API="https://api.github.com/repos/tinyhumansai/openhuman/releases/latest"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 权限检查
if [ "$(id -u)" -ne 0 ]; then
    error "请使用 root 用户执行此脚本"
    exit 1
fi

# ===================== 1. 环境准备 =====================
info "更新软件包并安装依赖..."
apt-get update -qq
apt-get install -y -qq curl git tar nginx logrotate pnpm 2>/dev/null || true
command -v pnpm &>/dev/null || npm install -g pnpm
mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$LOG_DIR"

systemctl stop openhuman-core 2>/dev/null || true
systemctl disable openhuman-core 2>/dev/null || true
pkill -9 -f "openhuman-core" 2>/dev/null || true

# ===================== 2. 获取源码并构建前端 =====================
cd "$INSTALL_DIR"
if [ ! -d ".git" ]; then
    info "克隆 OpenHuman 仓库..."
    git clone "$REPO_URL" .
else
    info "更新现有仓库..."
    git pull origin main || git pull origin master
fi

if [ "${SKIP_BUILD:-0}" != "1" ] || [ ! -d "$INSTALL_DIR/app/dist" ]; then
    info "安装前端依赖并构建（约 3-5 分钟）..."
    pnpm install --frozen-lockfile
    pnpm build
fi

DIST_PATH=$(find "$INSTALL_DIR" -type d -name "dist" | grep -v node_modules | head -1)
if [ -z "$DIST_PATH" ]; then
    error "前端构建失败，未找到 dist 目录"
    exit 1
fi
info "前端目录: $DIST_PATH"

# ===================== 3. 注入版本检查绕过 =====================
info "注入版本检查绕过代码..."
for jsfile in "$DIST_PATH/assets"/*.js; do
    if ! grep -q "SKIP_VERSION_CHECK" "$jsfile"; then
        sed -i '1i window.__OH_SKIP_VERSION_CHECK = true;' "$jsfile"
    fi
done
sed -i '/<head>/a <script>localStorage.setItem("ignoreCoreVersion", "true");</script>' "$DIST_PATH/index.html"

# ===================== 4. 下载核心二进制 =====================
if [ ! -f "$CORE_BIN" ] || [ "${FORCE_UPDATE_CORE:-0}" = "1" ]; then
    info "获取最新核心版本..."
    LATEST_VERSION=$(curl -s "$GITHUB_API" | grep -oP '"tag_name": "\K(.*?)(?=")')
    if [ -z "$LATEST_VERSION" ]; then
        error "无法获取最新版本号"
        exit 1
    fi
    VERSION_NO_V="${LATEST_VERSION#v}"
    TAR_NAME="openhuman-core-${VERSION_NO_V}-aarch64-unknown-linux-gnu.tar.gz"
    DOWNLOAD_URL="https://github.com/tinyhumansai/openhuman/releases/download/${LATEST_VERSION}/${TAR_NAME}"

    info "下载核心: $LATEST_VERSION"
    curl -L -o "/tmp/${TAR_NAME}" "$DOWNLOAD_URL"

    # 校验（如果官方提供 checksum）
    CHECKSUM_URL="https://github.com/tinyhumansai/openhuman/releases/download/${LATEST_VERSION}/checksums.txt"
    curl -s -L -o /tmp/checksums.txt "$CHECKSUM_URL" 2>/dev/null || true
    if [ -f /tmp/checksums.txt ]; then
        EXPECTED_HASH=$(grep "$TAR_NAME" /tmp/checksums.txt | awk '{print $1}')
        if [ -n "$EXPECTED_HASH" ]; then
            ACTUAL_HASH=$(sha256sum "/tmp/${TAR_NAME}" | awk '{print $1}')
            if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
                error "SHA256 校验失败！"
                exit 1
            fi
            info "SHA256 校验通过"
        fi
    else
        info "未找到校验文件，跳过完整性检查"
    fi

    info "解压并安装核心..."
    mkdir -p /tmp/openhuman_extract
    tar -xzf "/tmp/${TAR_NAME}" -C /tmp/openhuman_extract
    CORE_FILE=$(find /tmp/openhuman_extract -type f -name "openhuman-core" -executable | head -1)
    if [ -z "$CORE_FILE" ]; then
        error "解压后未找到 openhuman-core 可执行文件，包内容如下："
        find /tmp/openhuman_extract -type f
        rm -rf /tmp/openhuman_extract "/tmp/${TAR_NAME}" /tmp/checksums.txt
        exit 1
    fi
    mv "$CORE_FILE" "$CORE_BIN"
    chmod +x "$CORE_BIN"
    rm -rf /tmp/openhuman_extract "/tmp/${TAR_NAME}" /tmp/checksums.txt
    info "核心程序安装完成: $CORE_BIN"
fi

# ===================== 5. 配置 Nginx =====================
info "配置 Nginx 反向代理..."
printf '%s\n' \
    "server {" \
    "    listen 127.0.0.1:$WEB_PORT;" \
    "    server_name localhost;" \
    "    root $DIST_PATH;" \
    "    index index.html;" \
    "    location / {" \
    "        try_files \$uri \$uri/ /index.html;" \
    "    }" \
    "    location /rpc {" \
    "        proxy_pass http://127.0.0.1:$RPC_PORT;" \
    "        proxy_http_version 1.1;" \
    "        proxy_set_header Upgrade \$http_upgrade;" \
    "        proxy_set_header Connection \"upgrade\";" \
    "        proxy_set_header Host \$host;" \
    "        proxy_set_header X-Real-IP \$remote_addr;" \
    "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" \
    "        proxy_read_timeout 86400;" \
    "    }" \
    "    access_log $LOG_DIR/nginx_access.log;" \
    "    error_log $LOG_DIR/nginx_error.log;" \
    "}" > /etc/nginx/sites-available/openhuman

ln -sf /etc/nginx/sites-available/openhuman /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx || { error "Nginx 配置失败"; exit 1; }

# ===================== 6. 创建 systemd 服务 =====================
printf '%s\n' \
    "[Unit]" \
    "Description=OpenHuman Core Service" \
    "After=network.target" \
    "" \
    "[Service]" \
    "Type=simple" \
    "User=root" \
    "ExecStart=$CORE_BIN run --db-path $DATA_DIR --listen 127.0.0.1:$RPC_PORT" \
    "Restart=always" \
    "RestartSec=10" \
    "StandardOutput=append:$LOG_DIR/core.log" \
    "StandardError=append:$LOG_DIR/core_error.log" \
    "Environment=\"OH_TOKEN_FILE=$CORE_TOKEN_FILE\"" \
    "" \
    "[Install]" \
    "WantedBy=multi-user.target" > /etc/systemd/system/openhuman-core.service

systemctl daemon-reload
systemctl enable openhuman-core

# ===================== 7. 日志轮转 =====================
printf '%s\n' \
    "$LOG_DIR/*.log {" \
    "    daily" \
    "    rotate 7" \
    "    compress" \
    "    delaycompress" \
    "    missingok" \
    "    notifempty" \
    "    create 0644 root root" \
    "}" > /etc/logrotate.d/openhuman

# ===================== 8. 启动核心 =====================
info "启动核心服务..."
systemctl start openhuman-core
sleep 5
if systemctl is-active --quiet openhuman-core; then
    info "核心服务运行正常"
else
    error "核心启动失败，请查看日志: journalctl -u openhuman-core"
    exit 1
fi

TOKEN=""
[ -f "$CORE_TOKEN_FILE" ] && TOKEN=$(cat "$CORE_TOKEN_FILE")

echo "========================================="
echo -e "${GREEN}✅ OpenHuman 生产环境部署完成！${NC}"
echo "访问地址:     http://127.0.0.1:$WEB_PORT"
echo "RPC 地址:     http://127.0.0.1:$RPC_PORT/rpc"
[ -n "$TOKEN" ] && echo "认证 Token:   $TOKEN"
echo "服务管理:     systemctl start|stop|restart openhuman-core"
echo "日志:         journalctl -fu openhuman-core"
echo "========================================="
