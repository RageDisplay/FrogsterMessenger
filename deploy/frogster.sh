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
  update [--force]    Back up, get the latest code, rebuild and restart.
                      Rolls back by itself if the new version does not start.
                      Data and secrets stay. --force rebuilds even when the
                      code has not changed.
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
	# The installer replaces this very file, and bash reads a script as it
	# runs it. Run the update from a copy, so the replacement cannot pull
	# the rest of the script out from under it.
	if [[ -z "${FROGSTER_UPDATE_COPY:-}" ]]; then
		copy="$(mktemp /tmp/frogster-update.XXXXXX)"
		cp "$0" "$copy"
		FROGSTER_UPDATE_COPY="$copy" FROGSTER_SELF="$0" exec bash "$copy" update "$@"
	fi
	trap 'rm -f "$FROGSTER_UPDATE_COPY"' EXIT
	self="${FROGSTER_SELF:-$0}"
	force=0
	[[ "${1:-}" == "--force" ]] && force=1
	git=(git -C "$DIR")

	if [[ -n "$("${git[@]}" status --porcelain --untracked-files=no)" ]]; then
		echo "frogster: $DIR has local changes; commit or discard them first:" >&2
		"${git[@]}" status --short --untracked-files=no >&2
		exit 1
	fi
	branch="$("${git[@]}" rev-parse --abbrev-ref HEAD)"
	before="$("${git[@]}" rev-parse HEAD)"

	echo "== Fetching $branch"
	"${git[@]}" fetch --quiet origin "$branch"
	after="$("${git[@]}" rev-parse "origin/$branch")"
	if [[ "$before" == "$after" && $force -eq 0 ]]; then
		echo "Already up to date ($("${git[@]}" log -1 --format='%h %s' HEAD))."
		exit 0
	fi
	if [[ "$before" != "$after" ]]; then
		echo "New in this update:"
		if "${git[@]}" merge-base --is-ancestor "$before" "$after"; then
			"${git[@]}" log --format='  %h %s' "$before..$after" | head -30
		else
			# The history on GitHub was rewritten (a force push, or the
			# repository was recreated). The server never has commits of its
			# own, so following the remote exactly is the right thing.
			echo "  (history was rewritten upstream; switching to it)"
			"${git[@]}" log --format='  %h %s' -10 "$after"
		fi
	fi

	echo "== Backing up the database first"
	"$self" backup

	# The new code goes in place, then the installer builds and starts it.
	# If it does not come up healthy, the previous version is put back.
	"${git[@]}" reset --quiet --hard "$after"
	if "$DEPLOY/install.sh" --yes --no-fetch --dir "$DIR"; then
		echo ""
		echo "Updated to $("${git[@]}" log -1 --format='%h %s' HEAD)."
		exit 0
	fi

	echo "" >&2
	echo "== The new version did not start; going back to $(git -C "$DIR" log -1 --format=%h "$before")" >&2
	"${git[@]}" reset --quiet --hard "$before"
	if "$DEPLOY/install.sh" --yes --no-fetch --dir "$DIR"; then
		echo "Rolled back: the server runs the previous version again." >&2
	else
		echo "The rollback did not start either. Look at: sudo frogster logs frogsterd" >&2
	fi
	latest="$(find "$BACKUPS" -maxdepth 1 -name 'frogster-*.sql.gz' | sort -r | head -1)"
	echo "If the database was changed by the failed version, restore it with:" >&2
	echo "  sudo frogster restore $latest" >&2
	exit 1
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
