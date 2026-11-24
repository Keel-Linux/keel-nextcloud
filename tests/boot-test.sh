#!/bin/bash
# Boot test of this appliance (org-plan section 1), modelled on the ones in
# keel-core, keel-nodebb and keel-wordpress: assemble the published layer
# chain into an LXC rootfs, boot it headless from tests/instance.yaml, wait
# for the first boot to finish, and then prove that the appliance does what
# it exists to do.
#
# What it proves, in order, and none of it by reading a file the build wrote:
#
#   1. status.php answers 200 over IPv6 on port 443 and on port 80 (no
#      redirect while the certificate is self-signed, decision 0079): nginx
#      and PHP-FPM serve Nextcloud, and it says installed, not in
#      maintenance, no database upgrade waiting
#   2. the login page answers 200 on both ports, /keel-health answers 204,
#      and the log in the data directory and config.php answer 404 (the
#      routes of tests/commission.yaml)
#   3. occ status says the same as status.php
#   4. the web user logs in over the socket with no password and reaches the
#      nextcloud database and its tables, and the lnmp account that
#      app.options.db_user names logs in with the declared db_password
#   5. Redis answers on its socket, and Nextcloud uses it for its file locks
#   6. the administrator logs in to WebDAV with the declared app_password,
#      and a wrong password is refused
#   7. the background jobs run from the keel-nextcloud-cron units
#   8. keel diff reports no drift between the spec and the machine
#
# Called by the reusable workflow test-appliance.yml after keel pull and keel
# verify; runnable by hand as root on any host with LXC. It builds nothing:
# the layers come from the mirror or from a directory bt-layer wrote. The
# logic lives in tests/lib/boot-test-lib.sh and is unit tested; this file is
# the thin main that touches the system. No secret is printed.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/boot-test-lib.sh
source "$here/lib/boot-test-lib.sh"

bt_parse_args "$@" || { rc=$?; [ "$rc" -eq 2 ] && exit 0; exit 1; }
BT_SPEC=${BT_SPEC:-$here/instance.yaml}
if [ "$(id -u)" -ne 0 ]; then
    echo "boot-test: must run as root (keel assemble, lxc-start)" >&2
    exit 1
fi
for tool in keel lxc-start lxc-info lxc-attach lxc-stop curl; do
    command -v "$tool" >/dev/null || { echo "boot-test: $tool not found" >&2; exit 1; }
done

container_dir=$BT_LXC_PATH/$BT_NAME
log() { printf '%s boot-test: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
lxc() { "lxc-$1" -P "$BT_LXC_PATH" -n "$BT_NAME" "${@:2}"; }
# Everything that needs a secret runs inside the container and reads it from
# the container's own /etc/keel/secrets, so no password is ever an argument of
# a command on this host, and none is printed.
inside() { lxc attach --clear-env -- /bin/bash -c "$1"; }

cleanup() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ -r "$BT_ROOTFS/var/log/inithooks.log" ]; then
        log "last lines of the container's inithooks log:"
        tail -n 60 "$BT_ROOTFS/var/log/inithooks.log"
    fi
    if [ "$BT_KEEP" -eq 1 ]; then
        log "keeping $BT_NAME under $BT_LXC_PATH (--keep); lxc-attach -P $BT_LXC_PATH -n $BT_NAME"
        return
    fi
    lxc stop -k >/dev/null 2>&1 || true
    rm -rf "$container_dir"
}
trap cleanup EXIT

# 1. Assemble the chain from the layers the build host published.
log "assembling $BT_APPLIANCE from $BT_LAYERS_DIR into $BT_ROOTFS"
lxc stop -k >/dev/null 2>&1 || true
rm -rf "$container_dir"
mkdir -p "$BT_ROOTFS"
keel pull "$BT_APPLIANCE" --source "$BT_LAYERS_DIR" --cache-dir "$BT_CACHE_DIR" --non-interactive
keel assemble "$BT_APPLIANCE" --rootfs "$BT_ROOTFS" --cache-dir "$BT_CACHE_DIR" --non-interactive

# 2. The container marks, the instance spec, the secrets it references and
#    the conf the first boot hooks read. The conf is what makes the first
#    boot headless; without it 30rootpass, 35mysqlpass and 40nextcloud wait
#    on a dialog forever.
log "installing the spec, the secrets and the conf into $BT_ROOTFS"
bt_mark_container "$BT_ROOTFS"
install -d -m 0700 "$BT_ROOTFS/etc/keel/secrets"
for target in $(bt_secret_targets "$BT_ROOTFS"); do
    bt_random_password > "$target"
    chmod 0600 "$target"
done
for target in $(bt_spec_targets "$BT_ROOTFS"); do
    install -D -m 0600 "$BT_SPEC" "$target"
done
bt_spec_in_rootfs "$BT_SPEC" "$BT_ROOTFS" > "$container_dir/instance-host.yaml"
# --root: the spec names the appliance, and the host does not hold its
# manifest. The layer ships it, so keel reads it from the assembled rootfs.
keel spec apply --spec "$container_dir/instance-host.yaml" --root "$BT_ROOTFS" \
    --conf "$BT_ROOTFS/etc/inithooks.conf" --non-interactive

# 3. Boot.
bt_lxc_config "$BT_NAME" "$BT_ROOTFS" "$BT_BRIDGE" > "$container_dir/config"
log "starting $BT_NAME on bridge $BT_BRIDGE"
lxc start -d

# 4. A global IPv6 address from the bridge.
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "a global IPv6 address on $BT_NAME" \
    bt_container_ipv6 "$BT_NAME" "$BT_LXC_PATH" > /dev/null
addr=$(bt_container_ipv6 "$BT_NAME" "$BT_LXC_PATH")
log "container address $addr"

# 5. First boot finished: 98finalize has cleared RUN_FIRSTBOOT and the
#    machine answers, on the console (confconsole's usage screen) or on SSH.
#    sshd is up long before the hooks are done, so the flag is what says the
#    first boot ended.
usage_screen() {
    lxc attach -- pgrep -f confconsole > /dev/null 2>&1
}
ssh_answers() {
    local banner
    # shellcheck disable=SC2016  # expanded by the inner bash, on purpose
    banner=$(timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1" && read -r -t 5 line <&3 && printf "%s" "$line"' \
        "$addr" "$BT_SSH_PORT" 2>/dev/null) || return 1
    bt_is_ssh_banner "$banner"
}
first_boot_done() {
    bt_firstboot_done_in "$BT_ROOTFS/etc/default/inithooks" || return 1
    usage_screen || ssh_answers
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "the first boot of $BT_NAME to finish" \
    first_boot_done
log "first boot finished; ssh root@$addr"

# 6. status.php over IPv6, on 443 and then on 80. PHP-FPM restarts at the
#    end of 40nextcloud, so the page is polled rather than fetched once.
status=$container_dir/status.json
code=""
status_answers() {
    code=$(curl -6 -k -sS -o "$status" -w '%{http_code}' "https://[$addr]/status.php" 2>/dev/null || true)
    [ "$code" = 200 ]
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "status.php on https://[$addr]/" status_answers
bt_status_verdict "https://[$addr]/status.php" 200 "$code"
bt_nextcloud_state_verdict "status.php on port 443" "$(cat "$status")"

status80=$container_dir/status-80.json
code80=$(curl -6 -sS -o "$status80" -w '%{http_code} %{redirect_url}' "http://[$addr]/status.php" 2>/dev/null || true)
bt_status_verdict "http://[$addr]/status.php (no redirect, decision 0079)" "200 " "$code80"
bt_nextcloud_state_verdict "status.php on port 80" "$(cat "$status80")"

# 7. The routes of the commissioning contract, asked from inside the
#    container on 127.0.0.1, which Nextcloud always trusts: the address of
#    the bridge is not known when the description is written.
route_code() {
    inside "curl -k -sS -o /dev/null -w '%{http_code}' '$1' 2>/dev/null" || true
}
bt_status_verdict "https://127.0.0.1/login" 200 "$(route_code https://127.0.0.1/login)"
bt_status_verdict "http://127.0.0.1/login" 200 "$(route_code http://127.0.0.1/login)"
bt_status_verdict "http://127.0.0.1/keel-health" 204 "$(route_code http://127.0.0.1/keel-health)"
bt_status_verdict "https://127.0.0.1/data/nextcloud.log" 404 "$(route_code https://127.0.0.1/data/nextcloud.log)"
bt_status_verdict "https://127.0.0.1/config/config.php" 404 "$(route_code https://127.0.0.1/config/config.php)"

# 8. occ, as the web user.
occ_status=$(inside "keel-occ status --output=json 2>/dev/null") \
    || { echo "boot-test: keel-occ status failed" >&2; exit 1; }
bt_nextcloud_state_verdict "occ status" "$occ_status"

# 9. The database, asked of the database. First the login the site makes:
#    the web user over the socket, with no password.
socket_report=$(inside "
    runuser -u $BT_NC_DB_LOGIN -- mysql --protocol=socket --batch \
        --skip-column-names --execute=\"
            SELECT CURRENT_USER(),
                   (SELECT COUNT(*) FROM information_schema.schemata
                     WHERE schema_name = '$BT_NC_DB_NAME'),
                   (SELECT COUNT(*) FROM information_schema.tables
                     WHERE table_schema = '$BT_NC_DB_NAME'
                       AND table_name = '$BT_NC_TABLE')\"
") || { echo "boot-test: $BT_NC_DB_LOGIN cannot log in over the socket" >&2; exit 1; }
bt_db_report_verdict "the web user (socket)" "$socket_report" "$BT_NC_DB_LOGIN" "$BT_NC_DB_NAME" "$BT_NC_TABLE"

#    Then the account of lnmp's 35mysqlpass, which app.options.db_user
#    names, with the secrets.db_password the container holds.
db_report=$(inside "
    MYSQL_PWD=\$(cat /etc/keel/secrets/db_password) mysql --user=$BT_LNMP_DB_USER \
        --host=127.0.0.1 --port=3306 --protocol=TCP --batch --skip-column-names --execute=\"
            SELECT CURRENT_USER(),
                   (SELECT COUNT(*) FROM information_schema.schemata
                     WHERE schema_name = '$BT_NC_DB_NAME'),
                   (SELECT COUNT(*) FROM information_schema.tables
                     WHERE table_schema = '$BT_NC_DB_NAME'
                       AND table_name = '$BT_NC_TABLE')\"
") || { echo "boot-test: the lnmp account $BT_LNMP_DB_USER cannot log in over 127.0.0.1:3306 with the declared secrets.db_password" >&2; exit 1; }
bt_db_report_verdict "the lnmp account $BT_LNMP_DB_USER (declared db_password)" "$db_report" "$BT_LNMP_DB_USER" "$BT_NC_DB_NAME" "$BT_NC_TABLE"

# 10. Redis on its socket, and the class Nextcloud uses for its file locks.
redis_info=$(inside "redis-cli -s $BT_REDIS_SOCKET INFO server" || true)
lock_class=$(inside "keel-occ config:system:get memcache.locking 2>/dev/null" || true)
bt_redis_verdict "$redis_info" "$lock_class"

# 11. A real login of the administrator, the proof of the commissioning
#     contract: a WebDAV PROPFIND of the home folder. curl reads the account
#     from its standard input, so the password is never an argument.
dav_code() {
    inside "printf 'user = \"$BT_NC_ADMIN_USER:%s\"\n' \"$1\" \
        | curl -K - -k -sS -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 0' \
            https://127.0.0.1/remote.php/dav/files/$BT_NC_ADMIN_USER/ 2>/dev/null" || true
}
# The command substitution is expanded by the shell inside the container.
# shellcheck disable=SC2016
bt_status_verdict "WebDAV of $BT_NC_ADMIN_USER with the declared app_password" 207 \
    "$(dav_code '$(cat /etc/keel/secrets/app_password)')"
bt_status_verdict "WebDAV of $BT_NC_ADMIN_USER with a wrong password" 401 \
    "$(dav_code not-the-password)"

# 12. The background jobs.
mode=$(inside "keel-occ config:app:get core backgroundjobs_mode 2>/dev/null" || true)
timer=$(inside "systemctl is-enabled $BT_CRON_TIMER 2>/dev/null" || true)
load=$(inside "systemctl show -p LoadState --value $BT_CRON_SERVICE" || true)
active=$(inside "systemctl show -p ActiveState --value $BT_CRON_SERVICE" || true)
bt_cron_verdict "$mode" "$timer" "$load" "$active"

# 13. No drift between the declared spec and the booted root.
set +e
keel diff --root "$BT_ROOTFS" --spec "$BT_SPEC"
code=$?
set -e
bt_diff_verdict "$code"
log "$BT_APPLIANCE boot test passed"
