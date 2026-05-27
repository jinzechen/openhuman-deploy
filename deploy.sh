#!/bin/bash
# OpenHuman 一键部署 (aarch64, root, 多镜像容错)
# 用法: curl -fsSL https://raw.githubusercontent.com/jinzechen/openhuman-deploy/main/deploy.sh | bash

set -o pipefail

INSTALL_DIR="/opt/openhuman"
DATA_DIR="/var/lib/openhuman"
LOG_DIR="/var/log/openhuman"
CORE_BIN="$INSTALL_DIR/openhuman-core"
CORE_TOKEN_FILE="$DATA_DIR/core.token"
WEB_PORT=3000
RPC_PORT=7788
REPO_URL="https://github.com/tinyhumansai/openhuman.git"
GITHUB_API="https://api.github.com/repos/tinyhumansai/openhuman/releases/latest"

# 候选镜像源（优先使用 ghproxy，其次为其他）
MIRRORS=(
    "https://ghproxy.com/"          # 常用 GitHub 加速
    "https://github.moeyy.xyz/"     # 备用镜像
    ""                               # 空表示直连
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[ "$(id -u)" -eq 0 ] || { error "请使用 root 用户"; exit 1; }

# ---------- 1. 依赖 ----------
info "1. 安装系统依赖..."
apt-get update -qq
apt-get install -y -qq curl git tar wget nginx logrotate pnpm 2>/dev/null || true
command -v pnpm &>/dev/null || npm install -g pnpm
mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$LOG_DIR"

systemctl stop openhuman-core 2>/dev/null || true
systemctl disable openhuman-core 2>/dev/null || true
pkill -9 -f "openhuman-core" 2>/dev/null || true

# ---------- 2. 源码更新 ----------
info "2. 更新源码..."
cd "$INSTALL_DIR"
if [ ! -d ".git" ]; then
    git clone "$REPO_URL" . || { error "克隆失败"; exit 1; }
else
    git fetch origin main && git reset --hard origin/main || warn "源码更新失败，使用旧版"
fi

# ---------- 3. 前端构建 ----------
if [ "${SKIP_BUILD:-0}" != "1" ] || [ ! -d "$INSTALL_DIR/app/dist" ]; then
    info "3. 构建前端（约 3~5 分钟）..."
    pnpm install --frozen-lockfile 2>&1 | grep -v "^╭\|^│\|^╰\|^Done" || true
    pnpm build || { error "前端构建失败"; exit 1; }
fi
DIST_PATH=$(find "$INSTALL_DIR" -type d -name "dist" | grep -v node_modules | head -1)
[ -z "$DIST_PATH" ] && { error "找不到 dist 目录"; exit 1; }
info "前端目录: $DIST_PATH"

# ---------- 4. 版本弹窗绕过 ----------
info "4. 注入版本绕过..."
INDEX_FILE="$DIST_PATH/index.html"
if [ -f "$INDEX_FILE" ]; then
    if grep -q "OH_SKIP_VERSION" "$INDEX_FILE"; then
        info "绕过代码已存在"
    else
        sed -i '/<head>/a\<script>window.__OH_SKIP_VERSION_CHECK = true; localStorage.setItem("ignoreCoreVersion","true");</script>' "$INDEX_FILE"
        info "注入完成"
    fi
fi

# ---------- 5. 下载核心二进制（多镜像重试） ----------
if [ ! -f "$CORE_BIN" ] || [ "${FORCE_UPDATE_CORE:-0}" = "1" ]; then
    info "5. 获取核心版本号..."
    for i in 1 2 3; do
        LATEST_VERSION=$(curl -s --retry 2 "$GITHUB_API" | grep -oP '"tag_name": "\K(.*?)(?=")')
        [ -n "$LATEST_VERSION" ] && break
        warn "API 失败，第 $i 次重试..."
        sleep 2
    done
    [ -z "$LATEST_VERSION" ] && { error "无法获取版本号，请检查网络"; exit 1; }

    VERSION_NO_V="${LATEST_VERSION#v}"
    TAR_NAME="openhuman-core-${VERSION_NO_V}-aarch64-unknown-linux-gnu.tar.gz"
    TAR_PATH="/tmp/${TAR_NAME}"
    ORIGIN_URL="https://github.com/tinyhumansai/openhuman/releases/download/${LATEST_VERSION}/${TAR_NAME}"

    # 尝试多个镜像源下载
    success=0
    for mirror in "${MIRRORS[@]}"; do
        if [ -z "$mirror" ]; then
            DOWNLOAD_URL="$ORIGIN_URL"
        else
            DOWNLOAD_URL="${mirror}${ORIGIN_URL}"
        fi
        info "尝试下载: $DOWNLOAD_URL"
        # wget: 断点续传, 重试3次, 超时60秒
        wget -c -t 3 -T 60 -O "$TAR_PATH" "$DOWNLOAD_URL" && {
            # 校验大小 >10MB
            SIZE=$(stat -c%s "$TAR_PATH" 2>/dev/null || 0)
            if [ "$SIZE" -gt 10485760 ]; then
                success=1
                info "下载成功 ($SIZE 字节)"
                break
            else
                warn "文件太小 ($SIZE)，可能不完整，重试下一个源..."
                rm -f "$TAR_PATH"
            fi
        } || warn "该源下载失败，切换下一个..."
    done

    if [ "$success" -ne 1 ]; then
        error "所有源下载失败。请手动下载 ${TAR_NAME} 并放入 /tmp/，然后重新执行本脚本。"
        echo "手动下载地址: $ORIGIN_URL"
        exit 1
    fi

    # 解压
    info "解压并安装..."
    mkdir -p /tmp/openhuman_extract
    tar -xzf "$TAR_PATH" -C /tmp/openhuman_extract || { error "解压失败"; exit 1; }
    CORE_FILE=$(find /tmp/openhuman_extract -type f -name "openhuman-core" -executable | head -1)
    [ -z "$CORE_FILE" ] && { error "未找到可执行文件"; exit 1; }
    mv "$CORE_FILE" "$CORE_BIN"
    chmod +x "$CORE_BIN"
    rm -rf /tmp/openhuman_extract "$TAR_PATH"
    info "核心安装完成: $CORE_BIN"
fi

# ---------- 6. Nginx + systemd ----------
info "6. 配置 Nginx 和 systemd..."
printf 'server {\n    listen 127.0.0.1:%s;\n    server_name localhost;\n    root %s;\n    index index.html;\n    location / {\n        try_files $uri $uri/ /index.html;\n    }\n    location /rpc {\n        proxy_pass http://127.0.0.1:%s;\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection "upgrade";\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_read_timeout 86400;\n    }\n    access_log %s/nginx_access.log;\n    error_log %s/nginx_error.log;\n}\n' "$WEB_PORT" "$DIST_PATH" "$RPC_PORT" "$LOG_DIR" "$LOG_DIR" > /etc/nginx/sites-available/openhuman

ln -sf /etc/nginx/sites-available/openhuman /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx || { error "Nginx 配置失败"; exit 1; }

cat > /etc/systemd/system/openhuman-core.service << EOF
[Unit]
Description=OpenHuman Core Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$CORE_BIN run --db-path $DATA_DIR --listen 127.0.0.1:$RPC_PORT
Restart=always
RestartSec=10
StandardOutput=append:$LOG_DIR/core.log
StandardError=append:$LOG_DIR/core_error.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openhuman-core

# 日志轮转
cat > /etc/logrotate.d/openhuman << EOF
$LOG_DIR/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF

# ---------- 7. 启动核心 ----------
info "7. 启动核心..."
systemctl start openhuman-core
sleep 5
if systemctl is-active --quiet openhuman-core; then
    info "核心运行正常"
else
    error "核心启动失败，查看: journalctl -u openhuman-core -n 50"
    exit 1
fi

TOKEN=""
[ -f "$CORE_TOKEN_FILE" ] && TOKEN=$(cat "$CORE_TOKEN_FILE")
[ -z "$TOKEN" ] && [ -f "$LOG_DIR/core.log" ] && TOKEN=$(grep -oP 'Token: \K.*' "$LOG_DIR/core.log" 2>/dev/null || true)

echo "========================================="
echo -e "${GREEN}✅ OpenHuman 部署完成！${NC}"
echo "访问:     http://127.0.0.1:$WEB_PORT"
echo "RPC:      http://127.0.0.1:$RPC_PORT/rpc"
[ -n "$TOKEN" ] && echo "Token:    $TOKEN" || warn "请手动查看 Token: journalctl -u openhuman-core"
echo "管理:     systemctl start|stop|restart openhuman-core"
echo "========================================="pkill -9 -f "openhuman-core" 2>/dev/null || true

# ================ 2. 源码更新 ================
info "2/7 更新源代码..."
cd "$INSTALL_DIR"
if [ ! -d ".git" ]; then
    git clone "$REPO_URL" . || { error "克隆失败"; exit 1; }
else
    git fetch origin main 2>/dev/null && git reset --hard origin/main 2>/dev/null || {
        warn "仓库更新失败，尝试使用现有代码..."
    }
fi

# ================ 3. 构建前端 ================
if [ "${SKIP_BUILD:-0}" != "1" ] || [ ! -d "$INSTALL_DIR/app/dist" ]; then
    info "3/7 构建前端（约 3~5 分钟）..."
    pnpm install --frozen-lockfile 2>&1 | grep -v "^╭\|^│\|^╰\|^Done" || true
    pnpm build || { error "前端构建失败"; exit 1; }
fi

DIST_PATH=$(find "$INSTALL_DIR" -type d -name "dist" | grep -v node_modules | head -1)
[ -z "$DIST_PATH" ] && { error "找不到 dist 目录"; exit 1; }
info "前端目录: $DIST_PATH"

# ================ 4. 处理版本弹窗 ================
info "4/7 注入版本绕过..."
INDEX_FILE="$DIST_PATH/index.html"
if [ -f "$INDEX_FILE" ]; then
    if grep -q "OH_SKIP_VERSION" "$INDEX_FILE"; then
        info "绕过代码已存在"
    else
        sed -i '/<head>/a\<script>window.__OH_SKIP_VERSION_CHECK = true; localStorage.setItem("ignoreCoreVersion","true");</script>' "$INDEX_FILE"
        info "注入完成"
    fi
else
    warn "未找到 index.html，无法注入"
fi

# ================ 5. 下载核心（带重试） ================
if [ ! -f "$CORE_BIN" ] || [ "${FORCE_UPDATE_CORE:-0}" = "1" ]; then
    info "5/7 下载核心程序..."

    # 获取版本号（重试 3 次）
    for i in 1 2 3; do
        LATEST_VERSION=$(curl -s --retry 2 "$GITHUB_API" | grep -oP '"tag_name": "\K(.*?)(?=")')
        [ -n "$LATEST_VERSION" ] && break
        warn "获取版本失败，第 $i 次重试..."
        sleep 2
    done
    [ -z "$LATEST_VERSION" ] && { error "无法获取最新版本号，请检查网络"; exit 1; }

    VERSION_NO_V="${LATEST_VERSION#v}"
    TAR_NAME="openhuman-core-${VERSION_NO_V}-aarch64-unknown-linux-gnu.tar.gz"
    DOWNLOAD_URL="https://github.com/tinyhumansai/openhuman/releases/download/${LATEST_VERSION}/${TAR_NAME}"

    info "版本: $LATEST_VERSION，开始下载..."
    curl -L --retry 3 --progress-bar -o "/tmp/${TAR_NAME}" "$DOWNLOAD_URL" || { error "下载失败"; exit 1; }

    # 解压
    mkdir -p /tmp/openhuman_extract
    tar -xzf "/tmp/${TAR_NAME}" -C /tmp/openhuman_extract || { error "解压失败"; exit 1; }
    CORE_FILE=$(find /tmp/openhuman_extract -type f -name "openhuman-core" -executable | head -1)
    [ -z "$CORE_FILE" ] && { error "找不到二进制文件"; exit 1; }

    mv "$CORE_FILE" "$CORE_BIN"
    chmod +x "$CORE_BIN"
    rm -rf /tmp/openhuman_extract "/tmp/${TAR_NAME}"
    info "核心安装完成: $CORE_BIN"
fi

# ================ 6. 配置 Nginx 和 Systemd ================
info "6/7 配置 Nginx 和 systemd..."

printf 'server {\n    listen 127.0.0.1:%s;\n    server_name localhost;\n    root %s;\n    index index.html;\n    location / {\n        try_files $uri $uri/ /index.html;\n    }\n    location /rpc {\n        proxy_pass http://127.0.0.1:%s;\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection "upgrade";\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_read_timeout 86400;\n    }\n    access_log %s/nginx_access.log;\n    error_log %s/nginx_error.log;\n}\n' "$WEB_PORT" "$DIST_PATH" "$RPC_PORT" "$LOG_DIR" "$LOG_DIR" > /etc/nginx/sites-available/openhuman

ln -sf /etc/nginx/sites-available/openhuman /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx || { error "Nginx 配置失败"; exit 1; }

# systemd 服务
cat > /etc/systemd/system/openhuman-core.service << EOF
[Unit]
Description=OpenHuman Core Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$CORE_BIN run --db-path $DATA_DIR --listen 127.0.0.1:$RPC_PORT
Restart=always
RestartSec=10
StandardOutput=append:$LOG_DIR/core.log
StandardError=append:$LOG_DIR/core_error.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openhuman-core

# 日志轮转
cat > /etc/logrotate.d/openhuman << EOF
$LOG_DIR/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF

# ================ 7. 启动核心 ================
info "7/7 启动核心服务..."
systemctl start openhuman-core
sleep 5

if systemctl is-active --quiet openhuman-core; then
    info "核心运行正常"
else
    error "核心启动失败，查看: journalctl -u openhuman-core -n 50"
    exit 1
fi

# 获取 Token
TOKEN=""
[ -f "$CORE_TOKEN_FILE" ] && TOKEN=$(cat "$CORE_TOKEN_FILE")
[ -z "$TOKEN" ] && [ -f "$LOG_DIR/core.log" ] && TOKEN=$(grep -oP 'Token: \K.*' "$LOG_DIR/core.log" 2>/dev/null || true)

echo "========================================="
echo -e "${GREEN}✅ OpenHuman 部署完成！${NC}"
echo "访问:     http://127.0.0.1:$WEB_PORT"
echo "RPC:      http://127.0.0.1:$RPC_PORT/rpc"
[ -n "$TOKEN" ] && echo "Token:    $TOKEN" || warn "请手动查看 Token: journalctl -u openhuman-core"
echo "管理:     systemctl start|stop|restart openhuman-core"
echo "========================================="
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
