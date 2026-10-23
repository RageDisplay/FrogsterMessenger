#!/usr/bin/env bash
# Frogster server installer for Ubuntu 22.04 / 24.04.
#
#   curl -fsSL https://raw.githubusercontent.com/<you>/FrogsterMessenger/main/deploy/install.sh | sudo bash
#   sudo ./deploy/install.sh                       # from a checkout
#   sudo ./deploy/install.sh --domain chat.example.com --email me@example.com --yes
#   sudo ./deploy/install.sh --ip 203.0.113.5 --yes
#
# Installs Docker, fetches the code, generates secrets once, configures TLS
# (Let's Encrypt for a domain or a bare IP, falling back to a private CA the
# app pins), opens the firewall, starts the stack and installs the `frogster`
# management command. Running it again is an update: secrets and data are
# kept.

set -Eeuo pipefail

DEFAULT_REPO="https://github.com/RageDisplay/FrogsterMessenger.git"
DEFAULT_DIR="/opt/frogster"

REPO_URL="${FROGSTER_REPO:-$DEFAULT_REPO}"
BRANCH="${FROGSTER_BRANCH:-main}"
INSTALL_DIR=""
DOMAIN=""
IP_ADDR=""
EMAIL=""
ASSUME_YES=0
NO_FIREWALL=0
SELF_SIGNED=0
FORCE_OS=0
NO_FETCH=0

# ---------------------------------------------------------------- output ----

if [[ -t 1 ]]; then
	C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_RED=$'\e[31m' C_CYAN=$'\e[36m'
else
	C_RESET="" C_BOLD="" C_GREEN="" C_YELLOW="" C_RED="" C_CYAN=""
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok() { printf '    %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() {
	printf '\n%sError:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
	exit 1
}

trap 'die "command failed on line $LINENO: $BASH_COMMAND"' ERR

usage() {
	cat <<'EOF'
Frogster server installer.

Options:
  --domain NAME     Serve on a domain name with a Let's Encrypt certificate.
  --ip ADDRESS      Serve on a bare public IP. Tries a Let's Encrypt IP
                    certificate first, falls back to a private CA.
  --email ADDRESS   Contact address for Let's Encrypt (recommended).
  --self-signed     Skip Let's Encrypt and use the private CA right away
                    (LAN or test installs).
  --dir PATH        Install location (default /opt/frogster, or the checkout
                    this script lives in).
  --repo URL        Git repository to install from.
  --branch NAME     Branch to install (default main).
  --no-firewall     Leave the firewall alone.
  --yes             Do not ask questions; fail if something is missing.
  --force           Run on an unsupported OS version.
  -h, --help        Show this help.
EOF
}

# ------------------------------------------------------------- arguments ----

while [[ $# -gt 0 ]]; do
	case "$1" in
	--domain) DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
	--ip) IP_ADDR="${2:?--ip needs a value}"; shift 2 ;;
	--email) EMAIL="${2:?--email needs a value}"; shift 2 ;;
	--self-signed) SELF_SIGNED=1; shift ;;
	--dir) INSTALL_DIR="${2:?--dir needs a value}"; shift 2 ;;
	--repo) REPO_URL="${2:?--repo needs a value}"; shift 2 ;;
	--branch) BRANCH="${2:?--branch needs a value}"; shift 2 ;;
	--no-firewall) NO_FIREWALL=1; shift ;;
	--yes | -y) ASSUME_YES=1; shift ;;
	--force) FORCE_OS=1; shift ;;
	# Used by `frogster update`, which has already put the code it wants
	# in place and only needs it built and started.
	--no-fetch) NO_FETCH=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown option: $1 (see --help)" ;;
	esac
done

[[ -n "$DOMAIN" && -n "$IP_ADDR" ]] && die "use either --domain or --ip, not both"

# Questions are read from the terminal, which still works when the script
# itself arrives on stdin through `curl | bash`.
ask() {
	local prompt="$1" default="${2:-}" answer=""
	if [[ $ASSUME_YES -eq 1 ]]; then
		printf '%s' "$default"
		return
	fi
	[[ -r /dev/tty ]] || die "no terminal to ask on; pass the answers as options (see --help)"
	if [[ -n "$default" ]]; then
		read -r -p "    $prompt [$default]: " answer </dev/tty
	else
		read -r -p "    $prompt: " answer </dev/tty
	fi
	printf '%s' "${answer:-$default}"
}

confirm() {
	[[ $ASSUME_YES -eq 1 ]] && return 0
	local answer
	answer="$(ask "$1 (y/n)" "y")"
	[[ "$answer" =~ ^[YyДд] ]]
}

# ---------------------------------------------------------------- checks ----

step "Checking the system"

[[ $EUID -eq 0 ]] || die "run as root (sudo)"

# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" || ! "${VERSION_ID:-}" =~ ^(22\.04|24\.04)$ ]]; then
	[[ $FORCE_OS -eq 1 ]] || die "supported on Ubuntu 22.04 and 24.04, found ${PRETTY_NAME:-unknown} (--force to try anyway)"
	warn "unsupported OS ${PRETTY_NAME:-unknown}, continuing because of --force"
else
	ok "$PRETTY_NAME"
fi

ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "amd64" || "$ARCH" == "arm64" ]] || die "unsupported architecture $ARCH"

MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
info "memory: ${MEM_MB} MB, architecture: $ARCH"

# Locate the source: the checkout this script lives in, if any.
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
CHECKOUT=""
if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then
	candidate="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
	[[ -f "$candidate/server/Dockerfile" && -f "$candidate/deploy/docker-compose.prod.yml" ]] && CHECKOUT="$candidate"
fi
if [[ -z "$INSTALL_DIR" ]]; then
	INSTALL_DIR="${CHECKOUT:-$DEFAULT_DIR}"
fi

# ------------------------------------------------------------------ swap ----

# Compiling the Go server needs about 1.5 GB; on a 1 GB VPS the compiler is
# killed by the OOM killer without swap.
if [[ $MEM_MB -lt 2000 ]] && ! swapon --show --noheadings | grep -q .; then
	step "Adding 2 GB of swap (low memory)"
	if [[ ! -f /swapfile ]]; then
		fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
		chmod 600 /swapfile
		mkswap /swapfile >/dev/null
	fi
	swapon /swapfile 2>/dev/null || warn "could not enable swap (container?); the build may run out of memory"
	grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
	ok "swap enabled"
fi

# -------------------------------------------------------------- packages ----

step "Installing packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git openssl ufw cron qrencode >/dev/null
ok "base packages"

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
	info "installing Docker from download.docker.com"
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc
	echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
		>/etc/apt/sources.list.d/docker.list
	apt-get update -qq
	apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
fi

if ! docker info >/dev/null 2>&1; then
	# systemd is absent in containers used to test this script.
	systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
	for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
	docker info >/dev/null 2>&1 || die "the Docker daemon is not running"
fi
ok "$(docker --version)"

# ---------------------------------------------------------------- source ----

step "Fetching Frogster"

if [[ $NO_FETCH -eq 1 ]]; then
	ok "using $INSTALL_DIR as it is"
elif [[ -d "$INSTALL_DIR/.git" ]]; then
	if [[ -n "$(git -C "$INSTALL_DIR" status --porcelain --untracked-files=no)" ]]; then
		warn "local changes in $INSTALL_DIR; installing them as they are, not pulling"
	elif ! git -C "$INSTALL_DIR" remote get-url origin >/dev/null 2>&1; then
		ok "using $INSTALL_DIR as it is (no remote to pull from)"
	else
		current="$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD)"
		git -C "$INSTALL_DIR" fetch --quiet origin "$current"
		git -C "$INSTALL_DIR" merge --quiet --ff-only "origin/$current" ||
			warn "could not fast-forward $current; installing the local version. 'sudo frogster update' handles a rewritten history."
		ok "at $(git -C "$INSTALL_DIR" rev-parse --short HEAD) ($current)"
	fi
elif [[ "$INSTALL_DIR" == "$CHECKOUT" ]]; then
	ok "using the files at $INSTALL_DIR"
else
	git clone --quiet --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
	ok "cloned $REPO_URL into $INSTALL_DIR"
fi

DEPLOY="$INSTALL_DIR/deploy"
ENV_FILE="$DEPLOY/.env"
COMPOSE=(docker compose --project-directory "$DEPLOY" -f "$DEPLOY/docker-compose.prod.yml" --env-file "$ENV_FILE")

touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
env_set() {
	local key="$1" value="$2"
	if grep -qE "^$key=" "$ENV_FILE"; then
		sed -i "s|^$key=.*|$key=$value|" "$ENV_FILE"
	else
		printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
	fi
}
# Secrets are generated once and never replaced: a new database password
# would lock the server out of its own data, a new JWT secret would sign
# everyone out, and a new storage key would make stored history unreadable.
env_secret() { [[ -n "$(env_get "$1")" ]] || env_set "$1" "$(openssl rand -hex 32)"; }

# ---------------------------------------------------------------- address ----

step "Choosing the server address"

PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
[[ -n "$PUBLIC_IP" ]] && info "public IP of this machine: $PUBLIC_IP"

# A previous run's choice is the default for this one.
PREV_SITE="$(env_get FROGSTER_SITE)"
PREV_MODE="$(env_get FROGSTER_TLS_MODE)"
[[ -z "$EMAIL" ]] && EMAIL="$(env_get ACME_EMAIL)"

if [[ -z "$DOMAIN" && -z "$IP_ADDR" ]]; then
	if [[ -n "$PREV_SITE" && $ASSUME_YES -eq 1 ]]; then
		if [[ "$PREV_MODE" == "domain" ]]; then DOMAIN="$PREV_SITE"; else IP_ADDR="$PREV_SITE"; fi
	elif [[ $ASSUME_YES -eq 1 ]]; then
		[[ -n "$PUBLIC_IP" ]] || die "could not detect the public IP; pass --domain or --ip"
		IP_ADDR="$PUBLIC_IP"
	else
		info "1) a domain name pointing at this server (best: a regular certificate)"
		info "2) the bare IP address $PUBLIC_IP"
		default_choice=2
		[[ "$PREV_MODE" == "domain" ]] && default_choice=1
		choice="$(ask "Choose 1 or 2" "$default_choice")"
		if [[ "$choice" == "1" ]]; then
			default_domain=""
			[[ "$PREV_MODE" == "domain" ]] && default_domain="$PREV_SITE"
			DOMAIN="$(ask "Domain name" "$default_domain")"
			[[ -n "$DOMAIN" ]] || die "a domain name is required"
		else
			default_ip="${PUBLIC_IP:-}"
			[[ "$PREV_MODE" != "domain" && -n "$PREV_SITE" ]] && default_ip="$PREV_SITE"
			IP_ADDR="$(ask "IP address" "$default_ip")"
			[[ -n "$IP_ADDR" ]] || die "an IP address is required"
		fi
	fi
fi

if [[ -n "$DOMAIN" ]]; then
	DOMAIN="${DOMAIN#http://}"
	DOMAIN="${DOMAIN#https://}"
	DOMAIN="${DOMAIN%%/*}"
	[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "'$DOMAIN' does not look like a domain name"
	SITE="$DOMAIN"
	MODE="domain"
	resolved="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}' || true)"
	if [[ -z "$resolved" ]]; then
		warn "$DOMAIN does not resolve yet; Let's Encrypt will fail until its A record points here"
	elif [[ -n "$PUBLIC_IP" && "$resolved" != "$PUBLIC_IP" ]]; then
		warn "$DOMAIN resolves to $resolved, but this machine is $PUBLIC_IP"
		confirm "Continue anyway?" || die "fix the DNS record and run again"
	else
		ok "$DOMAIN resolves to this machine"
	fi
else
	[[ "$IP_ADDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$IP_ADDR" == "localhost" ]] || die "'$IP_ADDR' is not an IPv4 address"
	SITE="$IP_ADDR"
	MODE="ip"
fi

if [[ -z "$EMAIL" && $SELF_SIGNED -eq 0 && $ASSUME_YES -eq 0 ]]; then
	EMAIL="$(ask "E-mail for Let's Encrypt notices (optional)" "")"
fi

# ------------------------------------------------------------ configuration --

step "Writing configuration"

env_secret POSTGRES_PASSWORD
env_secret REDIS_PASSWORD
env_secret FROGSTER_JWT_SECRET
env_secret FROGSTER_STORAGE_KEY
env_set FROGSTER_SITE "$SITE"
env_set FROGSTER_TLS_MODE "$MODE"
env_set ACME_EMAIL "$EMAIL"
if [[ -d "$INSTALL_DIR/.git" ]]; then
	env_set FROGSTER_VERSION "$(git -C "$INSTALL_DIR" describe --tags --always --dirty 2>/dev/null || echo dev)"
fi
ok "secrets in $ENV_FILE (readable by root only)"

# render_caddyfile acme|internal
render_caddyfile() {
	local issuer="$1" email_line="" tls_block="" ca_block=""
	[[ -n "$EMAIL" ]] && email_line="email $EMAIL"

	if [[ "$issuer" == "internal" ]]; then
		tls_block="tls internal"
		# The app downloads the private root certificate from here and trusts
		# it only if its fingerprint matches the one the installer prints and
		# the user types in. The download itself needs no protection: the
		# fingerprint check is what makes it trustworthy.
		ca_block="handle /.well-known/frogster-ca.crt {
		root * /data/caddy/pki/authorities/local
		rewrite * /root.crt
		header Content-Type application/x-pem-file
		file_server
	}"
	elif [[ "$MODE" == "ip" ]]; then
		# Let's Encrypt issues IP-address certificates only under the
		# short-lived profile (about six days); Caddy renews them itself.
		tls_block="tls {
		issuer acme {
			profile shortlived
		}
	}"
	fi

	local tmp
	tmp="$(mktemp)"
	SITE="$SITE" EMAIL_LINE="$email_line" TLS_BLOCK="$tls_block" CA_BLOCK="$ca_block" \
		awk '
		# Comment lines name the placeholders themselves; leave them alone,
		# or a multi-line value would spill out of the comment.
		/^#/ { print; next }
		{
			gsub(/__SITE__/, ENVIRON["SITE"]);
			gsub(/__EMAIL_LINE__/, ENVIRON["EMAIL_LINE"]);
			gsub(/__TLS_BLOCK__/, ENVIRON["TLS_BLOCK"]);
			gsub(/__CA_BLOCK__/, ENVIRON["CA_BLOCK"]);
			print
		}' "$DEPLOY/Caddyfile.tmpl" >"$tmp"
	install -m 0644 "$tmp" "$DEPLOY/Caddyfile"
	rm -f "$tmp"
	env_set FROGSTER_TLS_ISSUER "$issuer"
}

ISSUER="acme"
[[ $SELF_SIGNED -eq 1 || "$SITE" == "localhost" ]] && ISSUER="internal"
# Once the private CA is in use, stay on it: switching would change the
# certificate every installed app has pinned.
[[ "$(env_get FROGSTER_TLS_ISSUER)" == "internal" && "$MODE" == "ip" && "$PREV_SITE" == "$SITE" ]] && ISSUER="internal"
render_caddyfile "$ISSUER"
ok "Caddyfile for $SITE ($MODE, $ISSUER certificate)"

# --------------------------------------------------------------- firewall ----

if [[ $NO_FIREWALL -eq 0 ]]; then
	step "Configuring the firewall"
	# Keep every port sshd listens on open, or enabling ufw locks us out.
	ssh_ports="$(ss -tlnpH 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}' | sort -u || true)"
	[[ -n "$ssh_ports" ]] || ssh_ports="22"
	for port in $ssh_ports; do ufw allow "$port/tcp" >/dev/null; done
	ufw allow 80/tcp >/dev/null
	ufw allow 443/tcp >/dev/null
	ufw allow 443/udp >/dev/null
	# Voice channels. Without it voice still works, over 443, with more delay.
	ufw allow 7882/udp >/dev/null
	ufw --force enable >/dev/null
	ok "open: ssh ($(echo "$ssh_ports" | tr '\n' ' ' | xargs)), 80, 443, 7882/udp (voice)"
	warn "if your provider has its own firewall or security group, open 80, 443 and 7882/udp there too"
fi

# ------------------------------------------------------------------ start ----

step "Building and starting the services (the first build takes a few minutes)"

"${COMPOSE[@]}" build --pull
"${COMPOSE[@]}" up -d --remove-orphans

wait_healthy() {
	local service="$1" timeout="$2" state=""
	for _ in $(seq 1 "$timeout"); do
		state="$(docker inspect --format '{{.State.Health.Status}}' "$("${COMPOSE[@]}" ps -q "$service")" 2>/dev/null || true)"
		[[ "$state" == "healthy" ]] && return 0
		sleep 1
	done
	return 1
}

wait_healthy frogsterd 180 || { "${COMPOSE[@]}" logs --tail=50 frogsterd >&2; die "frogsterd did not become healthy"; }
ok "frogsterd is up"
wait_healthy filed 120 || { "${COMPOSE[@]}" logs --tail=50 filed >&2; die "filed did not become healthy"; }
ok "filed is up"

# ---------------------------------------------------------------- TLS check --

step "Checking TLS"

https_ok() {
	# --connect-to sends the request to this machine while still checking the
	# certificate against $SITE, so the test does not depend on DNS caches or
	# on the provider routing the public address back to itself.
	curl -fsS --max-time 5 --connect-to "$SITE:443:127.0.0.1:443" "$@" "https://$SITE/readyz" >/dev/null 2>&1
}

if [[ "$ISSUER" == "acme" ]]; then
	info "waiting for Let's Encrypt (up to 3 minutes)"
	got_cert=0
	for _ in $(seq 1 36); do
		https_ok && { got_cert=1; break; }
		sleep 5
	done
	if [[ $got_cert -eq 1 ]]; then
		ok "trusted certificate in place"
	elif [[ "$MODE" == "ip" ]]; then
		warn "Let's Encrypt did not issue a certificate for $SITE; switching to the private CA"
		render_caddyfile internal
		ISSUER="internal"
		"${COMPOSE[@]}" restart caddy >/dev/null
	else
		"${COMPOSE[@]}" logs --tail=30 caddy >&2 || true
		warn "no certificate yet. Check that $DOMAIN points here and ports 80/443 are reachable;"
		warn "Caddy keeps retrying on its own. Logs: frogster logs caddy"
	fi
fi

FINGERPRINT=""
if [[ "$ISSUER" == "internal" ]]; then
	for _ in $(seq 1 30); do
		if root_pem="$("${COMPOSE[@]}" exec -T caddy cat /data/caddy/pki/authorities/local/root.crt 2>/dev/null)" && [[ -n "$root_pem" ]]; then
			FINGERPRINT="$(printf '%s\n' "$root_pem" | openssl x509 -outform der | sha256sum | awk '{print toupper($1)}')"
			break
		fi
		sleep 2
	done
	[[ -n "$FINGERPRINT" ]] || die "Caddy did not create its private CA"
	https_ok -k || warn "HTTPS is not answering yet; check: frogster logs caddy"
	ok "private CA ready"
fi

# ------------------------------------------------------------- management ----

step "Installing the frogster command and daily backups"

install -m 0755 "$DEPLOY/frogster.sh" /usr/local/bin/frogster
mkdir -p /etc/frogster
printf 'FROGSTER_DIR=%s\n' "$INSTALL_DIR" >/etc/frogster/frogster.conf
mkdir -p /var/backups/frogster
chmod 700 /var/backups/frogster
cat >/etc/cron.d/frogster-backup <<'EOF'
# Nightly database backup, seven kept. Managed by the Frogster installer.
17 3 * * * root /usr/local/bin/frogster backup --quiet
EOF
chmod 644 /etc/cron.d/frogster-backup
ok "frogster status | logs | update | backup | restore | fingerprint"

# ---------------------------------------------------------------- summary ----

ADDRESS="https://$SITE"
printf '\n%s%s Frogster is running %s\n\n' "$C_GREEN" "$C_BOLD" "$C_RESET"
printf '  Server address for the app:  %s%s%s\n' "$C_BOLD" "$ADDRESS" "$C_RESET"
if [[ -n "$FINGERPRINT" ]]; then
	SHORT="$(echo "$FINGERPRINT" | cut -c1-32 | sed 's/.\{4\}/&-/g; s/-$//')"
	printf '  Certificate fingerprint:     %s%s%s\n' "$C_BOLD" "$SHORT" "$C_RESET"
	printf '\n  The server uses its own certificate authority. When the app\n'
	printf '  asks, compare the fingerprint it shows with the one above.\n'
	printf '  Show it again any time: frogster fingerprint\n'
	CONNECT="frogster://connect?server=$ADDRESS&ca=$FINGERPRINT"
else
	CONNECT="frogster://connect?server=$ADDRESS"
fi
if command -v qrencode >/dev/null 2>&1 && [[ -t 1 ]]; then
	printf '\n  Or scan this in the app:\n\n'
	qrencode -t ANSIUTF8 -m 2 "$CONNECT" | sed 's/^/  /'
fi
printf '\n  Config and secrets: %s\n' "$ENV_FILE"
printf '  Backups:            /var/backups/frogster (daily at 03:17)\n\n'
