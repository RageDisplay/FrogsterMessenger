#!/usr/bin/env bash
# Frogster management command, installed as /usr/local/bin/frogster by
# deploy/install.sh.

set -Eeuo pipefail

CONF=/etc/frogster/frogster.conf
[[ -r "$CONF" ]] || { echo "frogster: $CONF not found; run deploy/install.sh first" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
DIR="${FROGSTER_DIR:?FROGSTER_DIR missing from $CONF}"
DEPLOY="$DIR/deploy"
BACKUPS=/var/backups/frogster
KEEP_BACKUPS=7

compose() {
	docker compose --project-directory "$DEPLOY" -f "$DEPLOY/docker-compose.prod.yml" --env-file "$DEPLOY/.env" "$@"
}

need_root() { [[ $EUID -eq 0 ]] || { echo "frogster: run with sudo" >&2; exit 1; }; }

usage() {
	cat <<'EOF'
Usage: frogster <command>

  status              Show the services and their health.
  logs [service]      Follow logs (frogsterd, filed, caddy, postgres, redis).
  restart [service]   Restart everything or one service.
  update              Pull the latest code and rebuild. Data and secrets stay.
  backup [--quiet]    Dump the database to /var/backups/frogster.
  restore FILE        Replace the database with a backup. Destroys current data.
  fingerprint         Print the certificate fingerprint for the app.
  reset               Delete ALL data: accounts, messages, attachments.
EOF
}

cmd="${1:-help}"
shift || true

case "$cmd" in
status)
	compose ps
	;;
logs)
	compose logs -f --tail=200 "$@"
	;;
restart)
	need_root
	compose restart "$@"
	;;
update)
	need_root
	exec "$DEPLOY/install.sh" --yes --dir "$DIR"
	;;
backup)
	need_root
	quiet=0
	[[ "${1:-}" == "--quiet" ]] && quiet=1
	mkdir -p "$BACKUPS"
	chmod 700 "$BACKUPS"
	file="$BACKUPS/frogster-$(date +%Y%m%d-%H%M%S).sql.gz"
	# Written to a temporary name first, so a failed dump never replaces a
	# good backup in the rotation below.
	compose exec -T postgres pg_dump -U frogster --clean --if-exists frogster | gzip >"$file.part"
	mv "$file.part" "$file"
	chmod 600 "$file"
	# Names embed the timestamp, so a reverse name sort is newest first.
	find "$BACKUPS" -maxdepth 1 -name 'frogster-*.sql.gz' | sort -r |
		tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f
	[[ $quiet -eq 1 ]] || echo "backup written to $file"
	;;
restore)
	need_root
	file="${1:?usage: frogster restore FILE}"
	[[ -r "$file" ]] || { echo "frogster: cannot read $file" >&2; exit 1; }
	read -r -p "This replaces the whole database with $file. Type RESTORE to continue: " answer </dev/tty
	[[ "$answer" == "RESTORE" ]] || { echo "aborted"; exit 1; }
	compose stop frogsterd filed
	gunzip -c "$file" | compose exec -T postgres psql -q -U frogster -d frogster -v ON_ERROR_STOP=1
	compose start frogsterd filed
	echo "restored from $file"
	;;
fingerprint)
	need_root
	if [[ "$(grep -E '^FROGSTER_TLS_ISSUER=' "$DEPLOY/.env" | cut -d= -f2-)" != "internal" ]]; then
		echo "This server uses a publicly trusted certificate; the app needs no fingerprint."
		exit 0
	fi
	compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt |
		openssl x509 -outform der | sha256sum | awk '{print toupper(substr($1,1,32))}' | sed 's/.\{4\}/&-/g; s/-$//'
	;;
reset)
	need_root
	echo "This deletes every account, message, key and attachment on this server."
	read -r -p "Type DELETE EVERYTHING to continue: " answer </dev/tty
	[[ "$answer" == "DELETE EVERYTHING" ]] || { echo "aborted"; exit 1; }
	compose down -v
	echo "All data deleted. Start again with: sudo $DEPLOY/install.sh"
	;;
help | -h | --help)
	usage
	;;
*)
	echo "frogster: unknown command '$cmd'" >&2
	usage >&2
	exit 1
	;;
esac
