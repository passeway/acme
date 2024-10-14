#!/bin/bash

# 脚本功能：
# 1. 提示用户输入域名
# 2. 安装 acme.sh
# 3. 创建软链接
# 4. 设置默认 CA 为 Let's Encrypt
# 5. 申请 ECC 证书
# 6. 安装证书到指定路径
# 7. 自动开放所需端口（80 和 443）
# 8. 设置自动续期
# 9. 验证证书安装

# 添加日志记录
LOG_FILE="/var/log/ssl_installation.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "========== $(date) =========="

# 设置变量
ACME_HOME="$HOME/.acme.sh"
INSTALL_DIR="/usr/local/bin"
CERT_DIR="/etc/x-ui"

# 检查必要的命令
REQUIRED_CMDS=("curl" "systemctl" "crontab")
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "缺少必要的命令：$cmd。请安装后重试。"
        exit 1
    fi
done

# 检查是否以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 用户或使用 sudo 运行此脚本。"
    exit 1
fi

# 1. 提示用户输入域名
read -p "请输入要申请证书的域名（例如 example.com）： " DOMAIN

# 简单的域名格式验证
if [[ ! "$DOMAIN" =~ ^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[a-zA-Z]{2,}$ ]]; then
    echo "输入的域名格式不正确，请重新运行脚本并输入有效的域名。"
    exit 1
fi

echo "您输入的域名是：$DOMAIN"

# 2. 安装 acme.sh
if [ -d "$ACME_HOME" ]; then
    echo "acme.sh 已经安装在 $ACME_HOME。"
else
    echo "正在安装 acme.sh..."
    curl https://get.acme.sh | sh
    if [ $? -ne 0 ]; then
        echo "acme.sh 安装失败，请检查网络连接或访问权限。"
        exit 1
    fi
    echo "acme.sh 安装完成。"
fi

# 3. 创建软链接
if [ -L "$INSTALL_DIR/acme.sh" ]; then
    echo "软链接 /usr/local/bin/acme.sh 已存在。"
else
    echo "正在创建软链接 /usr/local/bin/acme.sh..."
    ln -s "$ACME_HOME/acme.sh" "$INSTALL_DIR/acme.sh"
    if [ $? -ne 0 ]; then
        echo "创建软链接失败，请检查权限。"
        exit 1
    fi
    echo "软链接创建完成。"
fi

# 加载 acme.sh 环境变量
if [ -f "$ACME_HOME/acme.sh.env" ]; then
    source "$ACME_HOME/acme.sh.env"
else
    echo "未找到 acme.sh.env 文件，跳过加载环境变量。"
fi

# 4. 设置默认 CA 为 Let's Encrypt
echo "设置默认 CA 为 Let's Encrypt..."
acme.sh --set-default-ca --server letsencrypt
if [ $? -ne 0 ]; then
    echo "设置默认 CA 失败。"
    exit 1
fi
echo "默认 CA 已设置为 Let's Encrypt。"

# 5. 自动开放所需端口（80 和 443）
echo "正在检测和开放所需的端口（80 和 443）..."

# 检查 Web 服务器状态
if systemctl is-active --quiet nginx; then
    echo "检测到 nginx 服务正在运行。"
elif systemctl is-active --quiet apache2; then
    echo "检测到 apache2 服务正在运行。"
else
    echo "未检测到 nginx 或 apache2 服务正在运行。请确保 Web 服务器已启动并使用正确的 Webroot。"
    exit 1
fi

# 函数：开放端口
open_port() {
    local PORT=$1
    local PROTOCOL=$2
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$PORT/$PROTOCOL" && echo "已开放端口 $PORT/$PROTOCOL (ufw)"
        ufw status | grep "$PORT/$PROTOCOL" >/dev/null 2>&1 || echo "警告：端口 $PORT/$PROTOCOL 可能未成功开放。"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$PORT"/"$PROTOCOL" && echo "已开放端口 $PORT/$PROTOCOL (firewalld)"
        firewall-cmd --reload
        firewall-cmd --list-ports | grep "$PORT/$PROTOCOL" >/dev/null 2>&1 || echo "警告：端口 $PORT/$PROTOCOL 可能未成功开放。"
    elif command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p "$PROTOCOL" --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -A INPUT -p "$PROTOCOL" --dport "$PORT" -j ACCEPT && echo "已开放端口 $PORT/$PROTOCOL (iptables)"
        # 保存 iptables 规则（视发行版而定）
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save
        elif command -v service >/dev/null 2>&1; then
            service iptables save
        fi
        iptables -L INPUT -v -n | grep "$PORT" >/dev/null 2>&1 || echo "警告：端口 $PORT/$PROTOCOL 可能未成功开放。"
    else
        echo "未检测到已知的防火墙管理工具（ufw, firewalld, iptables）。请手动开放端口 80 和 443。"
    fi
}

# 开放 HTTP (80) 和 HTTPS (443) 端口
open_port 80 tcp
open_port 443 tcp

echo "端口开放完成。"

# 6. 申请 ECC 证书
echo "正在申请 ECC 证书..."
read -p "请输入 Webroot 路径（默认 /var/www/html）： " WEBROOT
WEBROOT=${WEBROOT:-/var/www/html}
mkdir -p "$WEBROOT"  # 确保 webroot 目录存在

acme.sh --issue -d "$DOMAIN" -k ec-256 --webroot "$WEBROOT"
if [ $? -ne 0 ]; then
    echo "证书申请失败。请确保域名已正确解析并且服务器可以通过 HTTP 进行验证。"
    exit 1
fi
echo "证书申请成功。"

# 7. 安装证书
echo "正在安装证书到 $CERT_DIR..."
# 确保目标目录存在
mkdir -p "$CERT_DIR"

read -p "请输入需要重载的服务名称（例如 x-ui），或按 Enter 跳过： " SERVICE_NAME
if [ -n "$SERVICE_NAME" ]; then
    RELOADCMD="systemctl reload $SERVICE_NAME"
else
    RELOADCMD=""
fi

if [ -n "$RELOADCMD" ]; then
    acme.sh --install-cert -d "$DOMAIN" \
        --ecc \
        --key-file "$CERT_DIR/server.key" \
        --fullchain-file "$CERT_DIR/server.crt" \
        --reloadcmd "$RELOADCMD"
else
    acme.sh --install-cert -d "$DOMAIN" \
        --ecc \
        --key-file "$CERT_DIR/server.key" \
        --fullchain-file "$CERT_DIR/server.crt"
fi

if [ $? -ne 0 ]; then
    echo "证书安装失败。"
    exit 1
fi
echo "证书已成功安装到 $CERT_DIR。"

# 8. 设置自动续期（acme.sh 默认已设置，此处可验证）
echo "正在检查自动续期任务..."
if command -v systemctl >/dev/null 2>&1 && systemctl list-timers | grep -q "acme"; then
    echo "自动续期任务已通过 systemd timers 设置。"
elif crontab -l | grep -q "acme.sh --cron"; then
    echo "自动续期任务已存在于 crontab。"
else
    echo "添加自动续期任务到 crontab..."
    (crontab -l 2>/dev/null; echo "0 0 * * * \"$ACME_HOME/acme.sh\" --cron --home \"$ACME_HOME\" > /dev/null") | crontab -
    if [ $? -ne 0 ]; then
        echo "添加自动续期任务失败。"
        exit 1
    fi
    echo "自动续期任务已添加到 crontab。"
fi

# 9. 验证证书安装
echo "正在验证证书安装情况..."
if [ -f "$CERT_DIR/server.crt" ] && [ -f "$CERT_DIR/server.key" ]; then
    echo "证书和私钥文件已正确安装："
    echo "证书文件：$CERT_DIR/server.crt"
    echo "私钥文件：$CERT_DIR/server.key"
    echo "您可以通过访问 https://$DOMAIN 来验证证书是否生效。"
else
    echo "证书文件或私钥文件不存在，请检查安装步骤。"
    exit 1
fi

echo "SSL 证书安装和端口开放过程完成。"
