#!/usr/bin/env bash
# Cloudflare Argo Tunnel + Xray (vmess/vless over WebSocket) one-key installer
#
# 重写于 2026-04: 修复历史问题
#   * 命令注入 (域名输入未引用)
#   * Alpine 包管理数组越界 / armv7 拼写错 / yum 系无 systemctl 包
#   * tunnel 凭据 UUID 解析错误 (cut -d= argo.log)
#   * $argo 未赋值导致备用链接 host 为空
#   * tunnel name 仅取一级 label, 跨 zone 误判已存在
#   * 命令/文档不一致 (cf vs argotunnel)
#   * 缺少 set -e/输入校验/端口占用检测/系统检测健壮性
#
# 兼容: Debian 11+/Ubuntu 20.04+/RHEL/Rocky/Alma 9+/Fedora 38+/Arch.
#       Alpine/OpenWrt 由于无 systemd, 暂不支持 (会明确报错退出).
# 可选环境变量:
#   XRAY_VERSION  (默认 latest, 例: v1.8.23)
#   CF_VERSION    (默认 latest, 例: 2024.10.0)

set -Eeuo pipefail

#----------------------------------------------------------------------------
# 常量
#----------------------------------------------------------------------------
INSTALL_DIR="/opt/argotunnel"
SYSTEMD_DIR="/etc/systemd/system"
CF_CRED_DIR="/root/.cloudflared"
LINK_PATH="/usr/local/bin/argotunnel"
LINK_ALIAS="/usr/local/bin/cf"
LOG_FILE="$INSTALL_DIR/argo.log"
V2RAY_FILE="$INSTALL_DIR/v2ray.txt"
CONFIG_JSON="$INSTALL_DIR/config.json"
CONFIG_YAML="$INSTALL_DIR/config.yaml"
CF_BIN="$INSTALL_DIR/cloudflared"
XRAY_BIN="$INSTALL_DIR/xray"
MANAGE_SH="$INSTALL_DIR/manage.sh"
SVC_CF="cloudflared.service"
SVC_XRAY="xray.service"

XRAY_VERSION="${XRAY_VERSION:-latest}"
CF_VERSION="${CF_VERSION:-latest}"

C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'; C_RESET=$'\e[0m'

log()  { printf '%s[INFO]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
errlog(){ printf '%s[ERR ]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()  { errlog "$*"; exit 1; }

on_err() {
	local code=$?
	errlog "脚本在第 $1 行失败 (exit=$code). 详细日志: $LOG_FILE"
	exit "$code"
}
trap 'on_err "$LINENO"' ERR

#----------------------------------------------------------------------------
# 预检
#----------------------------------------------------------------------------
require_root() {
	[ "${EUID:-$(id -u)}" -eq 0 ] || die "请以 root 运行 (例: sudo bash $0)"
}

require_systemd() {
	if ! command -v systemctl >/dev/null 2>&1 || ! [ -d /run/systemd/system ]; then
		die "未检测到 systemd. 本脚本不支持当前系统 (Alpine/OpenWrt 等), 请改用对应 OpenRC/procd 配置."
	fi
}

detect_pkg_mgr() {
	[ -r /etc/os-release ] || die "无法读取 /etc/os-release"
	# shellcheck disable=SC1091
	. /etc/os-release
	local idlike=" ${ID:-} ${ID_LIKE:-} "
	case "$idlike" in
		*" debian "*|*" ubuntu "*) PKG_MGR=apt ;;
		*" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*)
			if command -v dnf >/dev/null 2>&1; then PKG_MGR=dnf; else PKG_MGR=yum; fi
			;;
		*" arch "*|*" archlinux "*) PKG_MGR=pacman ;;
		*" alpine "*) PKG_MGR=apk ;;
		*)
			if   command -v apt-get >/dev/null 2>&1; then PKG_MGR=apt
			elif command -v dnf      >/dev/null 2>&1; then PKG_MGR=dnf
			elif command -v yum      >/dev/null 2>&1; then PKG_MGR=yum
			elif command -v pacman   >/dev/null 2>&1; then PKG_MGR=pacman
			elif command -v apk      >/dev/null 2>&1; then PKG_MGR=apk
			else die "未识别的包管理器 (ID=${ID:-unknown})"
			fi
			;;
	esac
	log "检测到包管理器: $PKG_MGR (ID=${ID:-?})"
}

pkg_install() {
	local pkgs=("$@")
	case "$PKG_MGR" in
		apt)
			DEBIAN_FRONTEND=noninteractive apt-get update -qq
			DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
			;;
		dnf)    dnf install -y "${pkgs[@]}" ;;
		yum)    yum install -y "${pkgs[@]}" ;;
		pacman) pacman -Sy --noconfirm --needed "${pkgs[@]}" ;;
		apk)    apk add --no-cache "${pkgs[@]}" ;;
	esac
}

ensure_deps() {
	local need=()
	local c
	for c in unzip curl jq; do
		command -v "$c" >/dev/null 2>&1 || need+=("$c")
	done
	if ! command -v ss >/dev/null 2>&1; then
		case "$PKG_MGR" in
			apt) need+=(iproute2) ;;
			*)   need+=(iproute)  ;;
		esac
	fi
	if [ "${#need[@]}" -gt 0 ]; then
		log "安装依赖: ${need[*]}"
		pkg_install "${need[@]}"
	fi
}

#----------------------------------------------------------------------------
# 架构
#----------------------------------------------------------------------------
detect_arch() {
	local m
	m="$(uname -m)"
	case "$m" in
		x86_64|amd64)    XRAY_ARCH="64";        CF_ARCH="amd64" ;;
		i386|i686)       XRAY_ARCH="32";        CF_ARCH="386"   ;;
		aarch64|arm64)   XRAY_ARCH="arm64-v8a"; CF_ARCH="arm64" ;;
		armv7l|armv7|armv8l) XRAY_ARCH="arm32-v7a"; CF_ARCH="arm" ;;
		armv6l)          XRAY_ARCH="arm32-v6";  CF_ARCH="arm"   ;;
		*) die "未适配架构: $m" ;;
	esac
	log "架构: $m -> xray=$XRAY_ARCH, cloudflared=$CF_ARCH"
}

#----------------------------------------------------------------------------
# 下载
#----------------------------------------------------------------------------
fetch() {
	local url="$1" dst="$2"
	log "下载: $url"
	curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$dst" "$url"
}

download_xray() {
	local url
	if [ "$XRAY_VERSION" = "latest" ]; then
		url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"
	else
		url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
	fi
	fetch "$url" "$INSTALL_DIR/xray.zip"
	rm -rf "$INSTALL_DIR/xray-extract"
	unzip -qo "$INSTALL_DIR/xray.zip" -d "$INSTALL_DIR/xray-extract"
	install -m 0755 "$INSTALL_DIR/xray-extract/xray" "$XRAY_BIN"
	rm -rf "$INSTALL_DIR/xray.zip" "$INSTALL_DIR/xray-extract"
	log "xray 版本: $("$XRAY_BIN" version | head -n1 || true)"
}

download_cloudflared() {
	local url
	if [ "$CF_VERSION" = "latest" ]; then
		url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
	else
		url="https://github.com/cloudflare/cloudflared/releases/download/${CF_VERSION}/cloudflared-linux-${CF_ARCH}"
	fi
	fetch "$url" "$CF_BIN"
	chmod 0755 "$CF_BIN"
	log "cloudflared 版本: $("$CF_BIN" --version 2>/dev/null | head -n1 || true)"
}

#----------------------------------------------------------------------------
# 校验 / 工具
#----------------------------------------------------------------------------
is_valid_domain() {
	local d="$1"
	[ "${#d}" -le 253 ] || return 1
	[[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

uuidgen_compat() {
	if [ -r /proc/sys/kernel/random/uuid ]; then
		cat /proc/sys/kernel/random/uuid
	elif command -v uuidgen >/dev/null 2>&1; then
		uuidgen | tr '[:upper:]' '[:lower:]'
	else
		head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' \
			| sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
	fi
}

sanitize_tunnel_name() {
	local d="$1" base hash
	base="$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]' | tr '.' '-' | tr -cd 'a-z0-9-')"
	hash="$(printf '%s' "$d" | sha256sum | cut -c1-6)"
	printf 'argo-%s-%s' "$base" "$hash"
}

pick_free_port() {
	local p
	local _i
	for _i in $(seq 1 50); do
		p=$(( (RANDOM % 40000) + 20000 ))
		if ! ss -lnt "sport = :$p" 2>/dev/null | awk 'NR>1' | grep -q .; then
			printf '%s' "$p"
			return 0
		fi
	done
	die "找不到空闲端口 (尝试 50 次)"
}

fetch_isp_label() {
	local ipv="$1" json
	if json="$(curl -"$ipv" -fsS --max-time 10 https://speed.cloudflare.com/meta 2>/dev/null)"; then
		jq -r '
			[.asOrganization, .country, .colo]
			| map(select(. != null and . != ""))
			| join("-")' <<<"$json" \
			| tr ' ' '_' \
			| tr -cd 'A-Za-z0-9_-'
		return 0
	fi
	printf 'argo-%s' "$(date +%Y%m%d)"
}

#----------------------------------------------------------------------------
# 配置 / systemd
#----------------------------------------------------------------------------
write_xray_config() {
	local proto="$1" port="$2" uuid="$3" path="$4"
	local inbound
	case "$proto" in
		vmess)
			inbound='
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "'"$uuid"'", "alterId": 0 } ] },'
			;;
		vless)
			inbound='
      "protocol": "vless",
      "settings": { "decryption": "none", "clients": [ { "id": "'"$uuid"'" } ] },'
			;;
		*) die "未知协议: $proto" ;;
	esac
	cat > "$CONFIG_JSON" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": ${port},
      "listen": "127.0.0.1",${inbound}
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${path}" }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
JSON
	chmod 0600 "$CONFIG_JSON"
	jq empty "$CONFIG_JSON"  # syntax check
}

write_cf_config() {
	local tunnel_uuid="$1" port="$2" hostname="$3"
	cat > "$CONFIG_YAML" <<YAML
tunnel: ${tunnel_uuid}
credentials-file: ${CF_CRED_DIR}/${tunnel_uuid}.json
protocol: http2

ingress:
  - hostname: ${hostname}
    service: http://127.0.0.1:${port}
  - service: http_status:404
YAML
	chmod 0600 "$CONFIG_YAML"
}

write_systemd_units() {
	local ips="$1" tunnel_name="$2"
	cat > "$SYSTEMD_DIR/$SVC_CF" <<UNIT
[Unit]
Description=Cloudflare Argo Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CF_BIN} --no-autoupdate --edge-ip-version ${ips} --protocol http2 tunnel --config ${CONFIG_YAML} run ${tunnel_name}
Restart=on-failure
RestartSec=5s
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

	cat > "$SYSTEMD_DIR/$SVC_XRAY" <<UNIT
[Unit]
Description=Xray
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${CONFIG_JSON}
Restart=on-failure
RestartSec=5s
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

	systemctl daemon-reload
	systemctl enable --now "$SVC_CF" "$SVC_XRAY"
}

#----------------------------------------------------------------------------
# Tunnel 流程
#----------------------------------------------------------------------------
cf_login_if_needed() {
	if [ -f "$CF_CRED_DIR/cert.pem" ]; then
		log "已检测到 $CF_CRED_DIR/cert.pem, 跳过浏览器授权."
		return 0
	fi
	log "需要 Cloudflare 授权 — 终端会输出一个 https URL, 用浏览器打开并选择要绑定的域名:"
	"$CF_BIN" tunnel login
	[ -f "$CF_CRED_DIR/cert.pem" ] || die "授权未完成 ($CF_CRED_DIR/cert.pem 不存在)"
}

tunnel_uuid_by_name() {
	local name="$1"
	local raw
	raw="$("$CF_BIN" tunnel list --output json 2>>"$LOG_FILE" || true)"
	[ -z "$raw" ] && return 0
	# 兼容 cloudflared 历史上出现过的几种顶层形状：裸数组 / { result: […] } / { tunnels: […] }
	# 以及 deleted_at vs deletedAt 字段名
	printf '%s' "$raw" | jq -r --arg n "$name" '
		( if type=="array" then .
		  elif (.result? // empty) then .result
		  elif (.tunnels? // empty) then .tunnels
		  else [] end )
		| .[]
		| select(.name==$n)
		| select(((.deleted_at // .deletedAt // "") | tostring) == "")
		| .id
	' 2>>"$LOG_FILE" | head -n1
}

ensure_tunnel() {
	local name="$1" uuid create_out
	uuid="$(tunnel_uuid_by_name "$name" || true)"
	if [ -n "$uuid" ]; then
		if [ -f "${CF_CRED_DIR}/${uuid}.json" ]; then
			log "复用已存在 tunnel: $name ($uuid)"
			printf '%s' "$uuid"
			return 0
		fi
		warn "tunnel $name 已存在但凭据缺失, 重建中."
		"$CF_BIN" tunnel cleanup "$name" >>"$LOG_FILE" 2>&1 || true
		"$CF_BIN" tunnel delete -f "$name" >>"$LOG_FILE" 2>&1 || true
	fi
	log "创建 tunnel: $name"
	# 抓取创建输出同时写入日志。cloudflared 输出例:
	#   Created tunnel <name> with id <UUID>
	#   Tunnel credentials written to /root/.cloudflared/<UUID>.json.
	create_out="$("$CF_BIN" tunnel create "$name" 2>&1)"
	printf '%s\n' "$create_out" >>"$LOG_FILE"
	uuid="$(printf '%s' "$create_out" \
		| grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' \
		| head -n1)"
	# Fallback: 查 list 接口 (适配未来 CLI 输出改变)
	[ -n "$uuid" ] || uuid="$(tunnel_uuid_by_name "$name" || true)"
	# Fallback: 扫描刚生成的凭据 json (cloudflared 总在 cred dir 写 <UUID>.json)
	if [ -z "$uuid" ]; then
		uuid="$(find "$CF_CRED_DIR" -maxdepth 1 -name '*.json' -newer "$CF_CRED_DIR/cert.pem" -printf '%f\n' 2>/dev/null \
			| sed -n 's/\.json$//p' \
			| head -n1)"
	fi
	[ -n "$uuid" ] || die "创建 tunnel 失败, 详见 $LOG_FILE"
	printf '%s' "$uuid"
}

route_dns() {
	local name="$1" hostname="$2"
	log "绑定 DNS: $hostname -> tunnel $name"
	"$CF_BIN" tunnel route dns --overwrite-dns "$name" "$hostname" >>"$LOG_FILE" 2>&1
}

#----------------------------------------------------------------------------
# 链接生成
#----------------------------------------------------------------------------
write_v2ray_links() {
	local proto="$1" uuid="$2" path="$3" host="$4" isp="$5"
	local ps_label
	ps_label="$(printf '%s' "$isp" | sed 's/_/ /g')"
	local vmess_b64 vless_url

	{
		printf '# Generated by argotunnel.sh on %s\n' "$(date -Iseconds)"
		printf '# host=%s  protocol=%s  ws-path=%s\n\n' "$host" "$proto" "$path"
		printf '## TLS / 443 (推荐, 通过 Cloudflare CDN)\n'

		if [ "$proto" = vmess ]; then
			vmess_b64="$(jq -cn --arg ps "${ps_label}_tls" \
			                 --arg add "$host" \
			                 --arg host "$host" \
			                 --arg id "$uuid" \
			                 --arg path "$path" '
				{ v:"2", ps:$ps, add:$add, port:"443", id:$id, aid:"0",
				  scy:"auto", net:"ws", type:"none",
				  host:$host, path:$path, tls:"tls", sni:$host }' \
				| base64 -w0)"
			printf 'vmess://%s\n\n' "$vmess_b64"
		else
			vless_url="vless://${uuid}@${host}:443?encryption=none&security=tls&type=ws&host=${host}&path=${path}&sni=${host}#${ps_label// /%20}_tls"
			printf '%s\n\n' "$vless_url"
		fi

		printf '## 备注\n'
		printf -- '- 443 端口可改为 2053 / 2083 / 2087 / 2096 / 8443\n'
		printf -- '- add 字段可替换为 Cloudflare 优选 IP 或 CDN IP\n'
		printf -- '- 若需要走明文 80 端口, 请在 Cloudflare 控制台关闭 "始终使用 HTTPS" 后, 用 host=%s, port=80, security=none 自行调整\n' "$host"
	} > "$V2RAY_FILE"
	chmod 0600 "$V2RAY_FILE"
}

#----------------------------------------------------------------------------
# 管理命令 (生成到 manage.sh)
#----------------------------------------------------------------------------
write_manage_cli() {
	cat > "$MANAGE_SH" <<'MGR'
#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/argotunnel"
CF_BIN="$INSTALL_DIR/cloudflared"
SVC_CF="cloudflared.service"
SVC_XRAY="xray.service"

status_of() {
	if systemctl is-active --quiet "$1"; then printf 'active'; else printf 'inactive'; fi
}

require_root() {
	[ "${EUID:-$(id -u)}" -eq 0 ] || { echo '请 sudo 运行' >&2; exit 1; }
}
require_root

clear
while :; do
	printf '\n=== argotunnel ===\n'
	printf 'cloudflared: %s   xray: %s\n\n' "$(status_of "$SVC_CF")" "$(status_of "$SVC_XRAY")"
	cat <<MENU
1) 列出 / 删除 tunnel
2) 启动服务
3) 停止服务
4) 重启服务
5) 卸载 (保留 ~/.cloudflared 凭据)
6) 彻底卸载 (含凭据, 下次需重新授权)
7) 查看 v2ray 链接
8) 升级二进制 (xray + cloudflared)
9) 查看最近日志
0) 退出
MENU
	read -rp '请选择 [默认0]: ' menu; menu="${menu:-0}"
	case "$menu" in
		1)
			"$CF_BIN" tunnel list || true
			read -rp '输入要删除的 tunnel name (留空跳过): ' t
			if [ -n "$t" ]; then
				"$CF_BIN" tunnel cleanup "$t" || true
				"$CF_BIN" tunnel delete -f "$t" || true
			fi
			;;
		2) systemctl start   "$SVC_CF" "$SVC_XRAY" ;;
		3) systemctl stop    "$SVC_CF" "$SVC_XRAY" ;;
		4) systemctl restart "$SVC_CF" "$SVC_XRAY" ;;
		5)
			systemctl disable --now "$SVC_CF" "$SVC_XRAY" 2>/dev/null || true
			rm -f "/etc/systemd/system/$SVC_CF" "/etc/systemd/system/$SVC_XRAY"
			rm -rf "$INSTALL_DIR" /usr/local/bin/argotunnel /usr/local/bin/cf
			systemctl daemon-reload
			echo '已卸载 (~/.cloudflared 已保留)'
			exit 0
			;;
		6)
			systemctl disable --now "$SVC_CF" "$SVC_XRAY" 2>/dev/null || true
			rm -f "/etc/systemd/system/$SVC_CF" "/etc/systemd/system/$SVC_XRAY"
			rm -rf "$INSTALL_DIR" /usr/local/bin/argotunnel /usr/local/bin/cf ~/.cloudflared
			systemctl daemon-reload
			echo '已彻底卸载. 请前往 https://dash.cloudflare.com/profile/api-tokens 删除遗留 Token.'
			exit 0
			;;
		7) cat "$INSTALL_DIR/v2ray.txt" 2>/dev/null || echo '未找到 v2ray.txt' ;;
		8)
			if [ -x "$INSTALL_DIR/argotunnel.sh" ]; then
				bash "$INSTALL_DIR/argotunnel.sh" --upgrade-only
			else
				echo '未找到原始安装脚本, 请重新 curl 下载 argotunnel.sh 后运行.'
			fi
			;;
		9)
			journalctl -u "$SVC_CF" -u "$SVC_XRAY" --no-pager -n 80 || true
			;;
		0) exit 0 ;;
		*) echo "无效选项: $menu" ;;
	esac
done
MGR
	chmod 0755 "$MANAGE_SH"
	ln -sf "$MANAGE_SH" "$LINK_PATH"
	ln -sf "$MANAGE_SH" "$LINK_ALIAS"
	# 把当前安装脚本一并保留, 供 "升级" 重用
	if [ -f "${BASH_SOURCE[0]}" ] && [ "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")" != "$INSTALL_DIR/argotunnel.sh" ]; then
		install -m 0755 "${BASH_SOURCE[0]}" "$INSTALL_DIR/argotunnel.sh"
	fi
}

#----------------------------------------------------------------------------
# 高层流程
#----------------------------------------------------------------------------
flow_install() {
	local protocol ips ans
	printf '请选择 xray 协议 [1]vmess  [2]vless (默认1): '
	read -r ans; ans="${ans:-1}"
	case "$ans" in 1) protocol=vmess ;; 2) protocol=vless ;; *) die "无效协议: $ans" ;; esac

	printf '请选择 argo 连接模式 [4]IPv4  [6]IPv6 (默认4): '
	read -r ans; ans="${ans:-4}"
	case "$ans" in 4|6) ips="$ans" ;; *) die "无效连接模式: $ans" ;; esac

	mkdir -p "$INSTALL_DIR"
	: > "$LOG_FILE"
	chmod 0700 "$INSTALL_DIR"

	log '停止可能存在的旧服务'
	systemctl disable --now "$SVC_CF" "$SVC_XRAY" >/dev/null 2>&1 || true

	download_cloudflared
	download_xray

	cf_login_if_needed

	local domain
	while :; do
		printf '请输入要绑定的完整域名 (例 sub.example.com): '
		read -r domain
		domain="${domain,,}"
		if is_valid_domain "$domain"; then break; fi
		warn '域名格式不合法 (仅允许 a-z0-9 与连字符, 至少两段), 请重试.'
	done

	local tname uuid wsuuid wspath port isp tunnel_uuid
	tname="$(sanitize_tunnel_name "$domain")"
	uuid="$(uuidgen_compat)"
	wsuuid="$(uuidgen_compat)"
	wspath="/${wsuuid//-/}"
	port="$(pick_free_port)"
	isp="$(fetch_isp_label "$ips")"

	log "tunnel name = $tname"
	log "local port  = $port"
	log "ws path     = $wspath"

	write_xray_config "$protocol" "$port" "$uuid" "$wspath"

	tunnel_uuid="$(ensure_tunnel "$tname")"
	route_dns "$tname" "$domain"
	write_cf_config "$tunnel_uuid" "$port" "$domain"
	write_systemd_units "$ips" "$tname"
	write_v2ray_links "$protocol" "$uuid" "$wspath" "$domain" "$isp"
	write_manage_cli

	sleep 1
	systemctl is-active --quiet "$SVC_CF"   || warn "cloudflared 未启动: journalctl -u $SVC_CF"
	systemctl is-active --quiet "$SVC_XRAY" || warn "xray 未启动: journalctl -u $SVC_XRAY"

	printf '\n%s========== 安装完成 ==========%s\n\n' "$C_CYAN" "$C_RESET"
	cat "$V2RAY_FILE"
	printf '\n管理命令: %sargotunnel%s  (别名: %scf%s)\n' "$C_GREEN" "$C_RESET" "$C_GREEN" "$C_RESET"
}

flow_uninstall() {
	log '停止并禁用服务'
	systemctl disable --now "$SVC_CF" "$SVC_XRAY" >/dev/null 2>&1 || true
	rm -f "$SYSTEMD_DIR/$SVC_CF" "$SYSTEMD_DIR/$SVC_XRAY"
	systemctl daemon-reload
	rm -rf "$INSTALL_DIR" "$LINK_PATH" "$LINK_ALIAS" "$CF_CRED_DIR"
	log '卸载完成. 如需彻底注销, 请前往 https://dash.cloudflare.com/profile/api-tokens 删除遗留 Token.'
}

flow_upgrade() {
	[ -d "$INSTALL_DIR" ] || die '未检测到既有安装.'
	detect_arch
	log '升级 cloudflared + xray'
	download_cloudflared
	download_xray
	systemctl restart "$SVC_CF" "$SVC_XRAY"
	log '升级完成.'
}

flow_clean_temp() {
	local f
	for f in ./xray.zip ./cloudflared-linux ./argo.log ./v2ray.txt /tmp/xray.zip; do
		[ -e "$f" ] && rm -f "$f" && log "已删除 $f"
	done
	log '清理完成 (仅清理当前目录与 /tmp 下的旧版本残留, 不影响 /opt/argotunnel/).'
}

#----------------------------------------------------------------------------
# main
#----------------------------------------------------------------------------
main() {
	if [ "${1:-}" = '--upgrade-only' ]; then
		require_root
		detect_pkg_mgr
		require_systemd
		flow_upgrade
		return
	fi

	require_root
	detect_pkg_mgr
	require_systemd
	ensure_deps
	detect_arch
	mkdir -p "$INSTALL_DIR"
	chmod 0700 "$INSTALL_DIR"
	touch "$LOG_FILE"

	clear
	cat <<EOF
${C_CYAN}=== Cloudflare Argo Tunnel + Xray 一键脚本 ===${C_RESET}
说明:
  - 安装模式需在 Cloudflare 已托管的域名上手动授权一次.
  - 首次授权后, 备份 /root/.cloudflared 至同路径可跳过浏览器登录.
  - 管理命令: ${C_GREEN}argotunnel${C_RESET} (别名 ${C_GREEN}cf${C_RESET})
  - 可选: 通过环境变量 XRAY_VERSION / CF_VERSION 固定上游版本.

  1) 一键安装服务
  2) 卸载服务 (含 ~/.cloudflared)
  3) 仅升级二进制 (xray + cloudflared)
  4) 清理当前目录的旧版临时文件
  0) 退出
EOF
	read -rp '请选择 [默认1]: ' mode; mode="${mode:-1}"
	case "$mode" in
		1) flow_install ;;
		2) flow_uninstall ;;
		3) flow_upgrade ;;
		4) flow_clean_temp ;;
		0) log '已退出'; exit 0 ;;
		*) die "无效选项: $mode" ;;
	esac
}

main "$@"
