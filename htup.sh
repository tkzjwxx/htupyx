#!/bin/bash
clear
echo "======================================================="
echo "🔥 完美闭环：Sing-box 1.13.x + Argo + WARP (最后大扫除版)"
echo "======================================================="

# ==========================================
# 1. 注入 NAT64 DNS 并安装官方客户端获取数据
# ==========================================
echo "🔧 正在注入救命 DNS 并安装官方 WARP 依赖..."
echo -e "nameserver 2a00:1098:2b::1\nnameserver 2606:4700:4700::1111" > /etc/resolv.conf
apt update -y && apt install -y curl wget jq gnupg2 -y

# 安装官方 warp-cli (针对 Ubuntu/Debian 纯 v6 优化)
if [ ! -f "/etc/wireguard/warp.conf" ]; then
    echo "📦 正在拉取官方 WARP 客户端来生成合法数据..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.p/cloudflare-client.list
    apt update -y && apt install cloudflare-warp -y
    
    # 强制让官方客户端在纯 v6 环境下生成物理本地 wireguard 配置文件
    echo "⏳ 正在让官方客户端生成合法指纹数据..."
    warp-cli --accept-tos registration new >/dev/null 2>&1
    warp-cli --accept-tos mode warp+tunnel >/dev/null 2>&1
    # 触发生成本地配置文件
    warp-cli --accept-tos generate-local-config /etc/wireguard/warp.conf >/dev/null 2>&1
fi

WARP_CONF="/etc/wireguard/warp.conf"
if [ ! -f "$WARP_CONF" ]; then
    echo "❌ 错误：官方客户端未能在该 HAX IP 上成功生成配置。"
    exit 1
fi

echo "✅ 官方数据生成成功！正在执行无损数据提取..."
# 严格保留空格等号切割法
PK=$(grep "PrivateKey" $WARP_CONF | awk -F' = ' '{print $2}' | tr -d ' ')
V4=$(grep "Address" $WARP_CONF | grep "\." | awk -F' = ' '{print $2}' | tr -d ' ')
V6=$(grep "Address" $WARP_CONF | grep ":" | awk -F' = ' '{print $2}' | tr -d ' ')
RES_VAL=$(grep -i "Reserved" $WARP_CONF | awk -F'=' '{print $2}' | tr -d ' #[]')
[ -z "$RES_VAL" ] && RES="[0,0,0]" || RES="[${RES_VAL}]"

# ==========================================
# 2. 自动安装核心依赖 (Sing-box & Cloudflared)
# ==========================================
ARCH=$(uname -m)
[ "$ARCH" == "x86_64" ] && ARCH_CF="amd64" || ARCH_CF="arm64"

if [ ! -f "/usr/local/bin/cloudflared" ]; then
    echo "📦 正在安装 Cloudflared..."
    wget -qO /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH_CF"
    chmod +x /usr/local/bin/cloudflared
fi

if [ ! -f "/usr/bin/sing-box" ]; then
    echo "📦 正在安装 Sing-box 最新版..."
    LAST_VER=$(curl -Ls https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    [ -z "$LAST_VER" ] && LAST_VER="1.13.11"
    wget -qO sing-box.deb "https://github.com/SagerNet/sing-box/releases/download/v${LAST_VER}/sing-box_${LAST_VER}_linux_${ARCH_CF}.deb"
    dpkg -i sing-box.deb >/dev/null 2>&1
    rm -f sing-box.deb
fi

# ==========================================
# 3. 核心参数交互
# ==========================================
echo "-------------------------------------------------------"
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "🔑 已自动生成全新 UUID: $UUID"

read -p "🎯 请输入本地监听端口 (回车默认 60001): " IN_PORT
IN_PORT=${IN_PORT:-60001}

read -p "🛡️ 请输入 Argo Tunnel Token: " ARGO_TOKEN
if [ -z "$ARGO_TOKEN" ]; then echo "❌ Token 不能为空！退出。"; exit 1; fi

read -p "🌐 请输入 Argo 绑定的域名: " ARGO_DOMAIN
if [ -z "$ARGO_DOMAIN" ]; then echo "❌ 域名不能为空！退出。"; exit 1; fi
echo "-------------------------------------------------------"

# ==========================================
# 4. 生成全新升级的 HTTPUpgrade 完美 JSON 图纸
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
        "type": "tcp",
        "server": "1.1.1.1",
        "detour": "warp-out"
      },
      {
        "tag": "dns_local",
        "type": "tcp",
        "server": "2001:4860:4860::8888"
      }
    ],
    "strategy": "prefer_ipv6"
  },
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp-out",
      "address": ["$V4", "$V6"],
      "private_key": "$PK",
      "peers": [
        {
          "address": "2606:4700:d0::a29f:c001",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "reserved": $RES,
          "allowed_ips": ["0.0.0.0/0", "::/0"]
        }
      ],
      "mtu": 1280
    }
  ],
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
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "default_domain_resolver": "dns_local",
    "rules": [
      { "inbound": "vless-in", "outbound": "warp-out" }
    ],
    "final": "direct"
  }
}
EOF

# ==========================================
# 5. 配置系统服务进程 (优化自适应升级传输)
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
ExecStart=/usr/local/bin/cloudflared tunnel --edge-ip-version 6 run --token $ARGO_TOKEN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ==========================================
# 6. 生成快捷查询脚本 (快捷键: j)
# ==========================================
cat <<EOF > /usr/local/bin/j
#!/bin/bash
echo -e "\n\033[1;36m=======================================================\033[0m"
echo -e "\033[1;32m🎉 Sing-box + Argo 节点配置信息 (HTTPUpgrade 协议)\033[0m"
echo -e "\033[1;36m=======================================================\033[0m"
echo -e "\n\033[1;33m[1] v2rayN / NekoBox 快速导入链接:\033[0m"
echo -e "\033[32mvless://${UUID}@${ARGO_DOMAIN}:443?type=httpupgrade&security=tls&path=%2Fwolovelangduo520&sni=${ARGO_DOMAIN}#Argo-HTTPUP-WARP\033[0m"
echo -e "\033[1;36m=======================================================\033[0m"
EOF
chmod +x /usr/local/bin/j

# ==========================================
# 7. 启动核心服务
# ==========================================
echo "⚙️ 正在拉起核心后台服务..."
systemctl daemon-reload
systemctl enable --now sing-box cloudflared >/dev/null 2>&1
systemctl restart sing-box cloudflared

sleep 3

# ==========================================
# 8. 终极过河拆桥：大扫除代码（就在这里执行！）
# ==========================================
if systemctl is-active --quiet sing-box; then
    echo "🧹 [大扫除启动] 核心服务运行完美，现在执行过河拆桥，卸载官方残留..."
    
    # 停止并无情卸载官方客户端
    systemctl stop warp-svc >/dev/null 2>&1
    apt purge cloudflare-warp -y >/dev/null 2>&1
    apt autoremove -y >/dev/null 2>&1
    
    # 抹去官方软件源和配置火种（但保留刚才生成的备份供Sing-box使用）
    rm -f /etc/apt/sources.list.p/cloudflare-client.list
    rm -rf /var/lib/cloudflare-warp
    
    echo "✨ 大扫除完毕！系统已恢复绝对纯净，只保留绿色轻量核心。"
    j
else
    echo "❌ 启动异常！核心图纸校验失败。"
    /usr/bin/sing-box run -c /etc/sing-box/config.json
fi
