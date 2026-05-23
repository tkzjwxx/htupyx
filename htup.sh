#!/bin/bash
clear
echo "======================================================="
echo "🚀 Sing-box 1.13.x (HTTPUpgrade) + Argo + WARP 终极自动化部署脚本"
echo "======================================================="

# ==========================================
# 1. 强制注入 NAT64 恢复纯 IPv6 的下载能力
# ==========================================
echo "🔧 正在修复 HAX 纯 IPv6 网络环境..."
echo -e "nameserver 2a00:1098:2b::1\nnameserver 2606:4700:4700::1111" > /etc/resolv.conf
apt update -y && apt install -y curl wget gnupg lsb-release

# ==========================================
# 2. 安装官方 WARP 客户端并开启 SOCKS5 代理托底
# ==========================================
if ! command -v warp-cli &> /dev/null; then
    echo "📦 正在安装 Cloudflare WARP 官方客户端..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    . /etc/os-release
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $VERSION_CODENAME main" | tee /etc/apt/sources.list.d/cloudflare-client.list
    apt update -y && apt install cloudflare-warp -y
    
    echo "⚙️ 正在配置 WARP 本地代理模式 (端口 40000)..."
    warp-cli --accept-tos registration new
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port 40000
    warp-cli --accept-tos connect
    sleep 3
else
    echo "✅ WARP 客户端已安装，跳过。"
fi

# ==========================================
# 3. 自动安装依赖 (Sing-box & Cloudflared)
# ==========================================
ARCH=$(uname -m)
[ "$ARCH" == "x86_64" ] && ARCH_CF="amd64" || ARCH_CF="arm64"

if [ ! -f "/usr/local/bin/cloudflared" ]; then
    echo "📦 正在安装 Cloudflared (Argo)..."
    wget -qO /usr/local/bin/cloudflared "https://ghfast.top/https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH_CF"
    chmod +x /usr/local/bin/cloudflared
fi

if [ ! -f "/usr/bin/sing-box" ]; then
    echo "📦 正在安装 Sing-box 最新稳定版..."
    LAST_VER=$(curl -Ls https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    [ -z "$LAST_VER" ] && LAST_VER="1.13.11"
    wget -qO sing-box.deb "https://ghfast.top/https://github.com/SagerNet/sing-box/releases/download/v${LAST_VER}/sing-box_${LAST_VER}_linux_${ARCH_CF}.deb"
    dpkg -i sing-box.deb >/dev/null 2>&1
    rm -f sing-box.deb
fi

# ==========================================
# 4. 核心参数交互与生成
# ==========================================
echo "-------------------------------------------------------"
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "🔑 已自动生成全新 UUID: $UUID"

read -p "🎯 请输入本地监听端口 (回车默认 60001): " IN_PORT
IN_PORT=${IN_PORT:-60001}

read -p "🛡️ 请输入 Argo Tunnel Token: " ARGO_TOKEN
if [ -z "$ARGO_TOKEN" ]; then echo "❌ Token 不能为空！退出。"; exit 1; fi

read -p "🌐 请输入 Argo 绑定的域名 (例如 us3.989269.xyz): " ARGO_DOMAIN
if [ -z "$ARGO_DOMAIN" ]; then echo "❌ 域名不能为空！退出。"; exit 1; fi
echo "-------------------------------------------------------"

# ==========================================
# 5. 物理清场并生成完美 JSON 图纸 (解耦架构)
# ==========================================
rm -rf /etc/sing-box/*.json
mkdir -p /etc/sing-box /var/lib/sing-box

cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "dns_direct", "address": "2606:4700:4700::1111", "detour": "direct" }
    ],
    "strategy": "prefer_ipv6"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $IN_PORT,
      "users": [{ "uuid": "$UUID" }],
      "transport": { 
        "type": "httpupgrade", 
        "path": "/wolovelangduo520" 
      }
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "warp-out",
      "server": "127.0.0.1",
      "server_port": 40000,
      "version": "5"
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "inbound": "vless-in", "outbound": "warp-out" }
    ],
    "final": "direct"
  }
}
EOF

# ==========================================
# 6. 配置系统服务进程
# ==========================================
cat <<EOF > /lib/systemd/system/sing-box.service
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run
Restart=on-failure
RestartSec=10
LimitNOFILE=Infinity

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=cloudflared
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --protocol http2 --edge-ip-version 6 run --token $ARGO_TOKEN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ==========================================
# 7. 生成快捷查询脚本 (快捷键: j)
# ==========================================
cat <<EOF > /usr/local/bin/j
#!/bin/bash
echo -e "\n\033[1;36m=======================================================\033[0m"
echo -e "\033[1;32m🎉 Sing-box + Argo 节点配置信息 (HTTPUpgrade 协议)\033[0m"
echo -e "\033[1;36m=======================================================\033[0m"

echo -e "\n\033[1;33m[1] v2rayN / NekoBox 快速导入链接:\033[0m"
echo -e "\033[32mvless://${UUID}@${ARGO_DOMAIN}:443?type=httpupgrade&security=tls&path=%2Fwolovelangduo520&sni=${ARGO_DOMAIN}#Argo-WARP-Node\033[0m"

echo -e "\n\033[1;33m[2] Clash Meta (yaml) 节点格式:\033[0m"
echo -e "\033[37m  - name: "Argo-WARP-Node"
    type: vless
    server: ${ARGO_DOMAIN}
    port: 443
    uuid: ${UUID}
    udp: true
    tls: true
    sni: ${ARGO_DOMAIN}
    network: httpupgrade
    httpupgrade-opts:
      path: "/wolovelangduo520"\033[0m"

echo -e "\n\033[1;33m[3] Sing-box (json) 客户端出站格式:\033[0m"
echo -e "\033[37m  {
    \"type\": \"vless\",
    \"tag\": \"Argo-WARP-Node\",
    \"server\": \"${ARGO_DOMAIN}\",
    \"server_port\": 443,
    \"uuid\": \"${UUID}\",
    \"tls\": {
      \"enabled\": true,
      \"server_name\": \"${ARGO_DOMAIN}\",
      \"insecure\": false
    },
    \"transport\": {
      \"type\": \"httpupgrade\",
      \"path\": \"/wolovelangduo520\"
    }
  }\033[0m"
echo -e "\033[1;36m=======================================================\033[0m"
echo -e "💡 \033[1;37m随时在终端输入 \033[1;31mj\033[1;37m 即可再次查看此信息。\033[0m\n"
EOF
chmod +x /usr/local/bin/j

# ==========================================
# 8. 启动服务并执行最终验收
# ==========================================
echo "⚙️ 正在拉起后台服务..."
systemctl daemon-reload
systemctl enable --now sing-box cloudflared >/dev/null 2>&1
systemctl restart sing-box cloudflared

sleep 3

if systemctl is-active --quiet sing-box; then
    j
else
    echo "❌ 启动异常！核心图纸校验失败或端口被占用。"
    echo "请运行 'journalctl -u sing-box -n 20' 查看具体死因。"
fi
