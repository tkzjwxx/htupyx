#!/bin/bash
clear
echo "======================================================="
echo "🚀 Sing-box 1.13+ Argo + WGCF (阅后即焚版) 自动化部署"
echo "======================================================="

# ==========================================
# 1. 临时 DNS 修复 (确保能连通 GitHub 和 CF)
# ==========================================
echo "🔧 正在修复纯 IPv6 网络解析..."
echo -e "nameserver 2a00:1098:2b::1\nnameserver 2606:4700:4700::1111" > /etc/resolv.conf
apt update -y && apt install -y curl wget jq

# ==========================================
# 2. 下载 WGCF 核心并自动注册 (核心亮点)
# ==========================================
ARCH=$(uname -m)
[ "$ARCH" == "x86_64" ] && ARCH_WGCF="amd64" || ARCH_WGCF="arm64"

echo "📦 正在拉取 WGCF 核心工具..."
# 使用 ghfast 镜像站防止 IPv6 无法下载
wget -qO wgcf "https://ghfast.top/https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${ARCH_WGCF}"
chmod +x wgcf

echo "⏳ 正在向 Cloudflare 申请原生 WARP 账号 (可能需要十几秒)..."
./wgcf register --accept-tos >/dev/null 2>&1
./wgcf generate >/dev/null 2>&1

if [ ! -f "wgcf-profile.conf" ]; then
    echo "❌ 致命错误：WGCF 注册失败！"
    echo "💡 原因：Cloudflare 拒绝了这台 HAX 机器的 IP 注册请求 (被判定为滥用或无法路由)。"
    echo "🧹 正在清理残留..."
    rm -f wgcf wgcf-account.toml
    exit 1
fi

echo "✅ 账号申请成功！正在提取私钥..."
PK=$(grep -i "PrivateKey" wgcf-profile.conf | awk -F'=' '{print $2}' | tr -d ' ')
V4=$(grep -i "Address" wgcf-profile.conf | grep "\." | awk -F'=' '{print $2}' | tr -d ' ')
V6=$(grep -i "Address" wgcf-profile.conf | grep ":" | awk -F'=' '{print $2}' | tr -d ' ')

# ==========================================
# 3. 阅后即焚 (卸载清理 WGCF)
# ==========================================
echo "🧹 提取完毕，执行阅后即焚，销毁 WGCF 及其生成的临时文件..."
rm -f wgcf wgcf-account.toml wgcf-profile.conf

# ==========================================
# 4. 自动安装依赖 (Sing-box & Cloudflared)
# ==========================================
if [ ! -f "/usr/local/bin/cloudflared" ]; then
    echo "📦 正在安装 Cloudflared..."
    wget -qO /usr/local/bin/cloudflared "https://ghfast.top/https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_WGCF}"
    chmod +x /usr/local/bin/cloudflared
fi

if [ ! -f "/usr/bin/sing-box" ]; then
    echo "📦 正在安装 Sing-box 最新稳定版..."
    LAST_VER=$(curl -Ls https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    [ -z "$LAST_VER" ] && LAST_VER="1.13.11"
    wget -qO sing-box.deb "https://ghfast.top/https://github.com/SagerNet/sing-box/releases/download/v${LAST_VER}/sing-box_${LAST_VER}_linux_${ARCH_WGCF}.deb"
    dpkg -i sing-box.deb >/dev/null 2>&1
    rm -f sing-box.deb
fi

# ==========================================
# 5. 核心参数交互与生成
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
# 6. 生成 Sing-box 1.13+ 完美配置
# ==========================================
rm -rf /etc/sing-box/*.json
mkdir -p /etc/sing-box /var/lib/sing-box

cat <<EOF > /etc/sing-box/config.json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns_remote",
        "type": "udp",
        "server": "1.1.1.1",
        "detour": "warp-out"
      },
      {
        "tag": "dns_local",
        "type": "udp",
        "server": "2606:4700:4700::1111"
      }
    ],
    "strategy": "prefer_ipv6"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $IN_PORT,
      "users": [
        { "uuid": "$UUID" }
      ],
      "transport": {
        "type": "httpupgrade",
        "path": "/wolovelangduo520"
      }
    }
  ],
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp-out",
      "address": [
        "$V4",
        "$V6"
      ],
      "private_key": "$PK",
      "peers": [
        {
          "address": "2606:4700:d0::a29f:c001",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "reserved": [0,0,0],
          "allowed_ips": ["0.0.0.0/0", "::/0"]
        }
      ],
      "mtu": 1280
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "default_domain_resolver": "dns_remote",
    "rules": [
      {
        "inbound": "vless-in",
        "outbound": "warp-out"
      }
    ],
    "final": "direct"
  }
}
EOF

# ==========================================
# 7. 配置系统服务进程
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
# 8. 生成快捷查询脚本 (快捷键: j)
# ==========================================
cat <<EOF > /usr/local/bin/j
#!/bin/bash
echo -e "\n\033[1;36m=======================================================\033[0m"
echo -e "\033[1;32m🎉 Sing-box + Argo 节点配置信息 (HTTPUpgrade协议)\033[0m"
echo -e "\033[1;36m=======================================================\033[0m"

echo -e "\n\033[1;33m[1] v2rayN / NekoBox 快速导入链接:\033[0m"
echo -e "\033[32mvless://${UUID}@${ARGO_DOMAIN}:443?type=httpupgrade&security=tls&path=%2Fwolovelangduo520&sni=${ARGO_DOMAIN}#Argo-WARP-Node\033[0m"
echo -e "\033[1;36m=======================================================\033[0m"
echo -e "💡 \033[1;37m随时在终端输入 \033[1;31mj\033[1;37m 即可再次查看此信息。\033[0m\n"
EOF
chmod +x /usr/local/bin/j

# ==========================================
# 9. 启动服务并执行最终验收
# ==========================================
echo "⚙️ 正在拉起后台服务..."
systemctl daemon-reload
systemctl enable --now sing-box cloudflared >/dev/null 2>&1
systemctl restart sing-box cloudflared

sleep 2

if systemctl is-active --quiet sing-box; then
    j
else
    echo "❌ 启动异常！核心图纸校验失败。"
    /usr/bin/sing-box run -c /etc/sing-box/config.json
fi
