#!/bin/bash
# Pure helpers of tests/boot-test.sh (decision 0004: logic apart from effect).
# Same shape as the ones in keel-core, keel-nodebb and keel-wordpress, with
# the checks this appliance adds: three secrets, a verdict on what
# status.php and occ status say, a verdict on what the database and Redis
# answer, and a verdict on the units of the background jobs. Nothing here
# starts a container, writes outside a path it is given or opens a socket.
# The functions that run a command take it from the environment or from
# PATH so a test can replace it. Sourced by boot-test.sh and by
# tests/boot-test.bats.
# shellcheck disable=SC2034  # the BT_* variables are read by the caller

BT_DEFAULT_TIMEOUT=900
BT_DEFAULT_INTERVAL=5
BT_DEFAULT_BRIDGE=lxcbr0
BT_DEFAULT_LAYERS_DIR=/mnt/builds/layers
BT_DEFAULT_CACHE_DIR=/var/cache/keel/layers
BT_DEFAULT_LXC_PATH=/var/lib/lxc
BT_SSH_PORT=22
BT_PASSWORD_LENGTH=24
BT_RANDOM_BYTES=1024
# The secrets tests/instance.yaml references, one file each under
# etc/keel/secrets in the rootfs: the root account, the lnmp database
# account that app.options.db_user names, and the Nextcloud administrator.
BT_SECRETS="root_password db_password app_password"
# Where the first boot reads the instance description. inithooks reads
# etc/inithooks.yaml (hook 00declarative), keel reads etc/keel/instance.yaml;
# the test installs the same file at both, as the other appliances do.
BT_SPEC_PATHS="etc/keel/instance.yaml etc/inithooks.yaml"
# What marks the tree as a container build, relative to the rootfs: the
# marker file bt-container writes and the inithooks defaults whose
# REDIRECT_OUTPUT it sets. See bt_mark_container.
BT_CONTAINER_MARKER="var/lib/turnkey-info/inithooks.service/lxc"
BT_INITHOOKS_DEFAULT="etc/default/inithooks"
BT_INITHOOKS_DROPIN="etc/systemd/system/inithooks.service.d/container.conf"
# The database of the site, its table prefix, the account the site logs in
# as (the web user over the socket, no password: 40nextcloud) and the lnmp
# account of 35mysqlpass that secrets.db_password opens. They are the values
# of tests/instance.yaml.
BT_NC_DB_NAME="nextcloud"
BT_NC_DB_LOGIN="www-data"
BT_NC_TABLE="oc_users"
BT_LNMP_DB_USER="admin"
BT_NC_ADMIN_USER="admin"
# The socket of the Redis of this layer, and the class Nextcloud must name
# for its file locks when Redis is in use.
BT_REDIS_SOCKET="/run/redis/redis-server.sock"
BT_REDIS_CLASS='\OC\Memcache\Redis'
# The units of the background jobs (keel-nextcloud-cron, 19.0-4).
BT_CRON_SERVICE="keel-nextcloud-cron.service"
BT_CRON_TIMER="keel-nextcloud-cron.timer"

bt_usage() {
    cat <<USAGE
usage: tests/boot-test.sh APPLIANCE [options]

Assembles the layer chain of APPLIANCE (nextcloud) into an LXC rootfs, boots
it headless from tests/instance.yaml, waits for the first boot to finish, and
then proves, in this order:

  status.php answers 200 over IPv6 on port 443 and on port 80, and says
    installed, not in maintenance, no database upgrade waiting
  the login page answers 200 on both ports, /keel-health answers 204, and
    the data and config paths answer 404
  occ status says the same as status.php
  the web user reaches the nextcloud database over the socket, and the lnmp
    account 'admin' logs in with the declared db_password
  Redis answers on its socket, and Nextcloud uses it for its file locks
  the administrator logs in to WebDAV with the declared app_password
  the background jobs run from the keel-nextcloud-cron units
  keel diff reports no drift

Root only.

options:
  --timeout SECONDS     give up after this long per wait (default $BT_DEFAULT_TIMEOUT)
  --interval SECONDS    poll interval (default $BT_DEFAULT_INTERVAL)
  --bridge NAME         bridge the container joins (default $BT_DEFAULT_BRIDGE)
  --layers-dir DIR|URL  where the layers are published: a directory, or an
                        http(s) URL such as https://mirror.keellinux.org/layers
                        (default $BT_DEFAULT_LAYERS_DIR)
  --cache-dir DIR       keel layer cache (default $BT_DEFAULT_CACHE_DIR)
  --lxc-path DIR        lxcpath for the test container (default $BT_DEFAULT_LXC_PATH)
  --name NAME           container name (default keel-APPLIANCE-boot-test)
  --spec FILE           instance spec (default tests/instance.yaml)
  --keep                leave the container running for inspection
  -h, --help            this text
USAGE
}

bt_is_positive_int() {
    [[ ${1-} =~ ^[1-9][0-9]*$ ]]
}

bt_is_appliance_name() {
    # The name bt-layer and the workflow use: no keel- prefix, lower case.
    [[ ${1-} =~ ^[a-z][a-z0-9-]*$ ]] && [[ $1 != keel-* ]]
}

bt_container_name() {
    printf 'keel-%s-boot-test\n' "$1"
}

bt_is_container_name() {
    # What LXC accepts and what the CI cleanup command allows: lower case
    # letters, digits, dot and dash, starting with a letter or a digit.
    [[ ${1-} =~ ^[a-z0-9][a-z0-9.-]*$ ]]
}

# Sets BT_APPLIANCE, BT_TIMEOUT, BT_INTERVAL, BT_BRIDGE, BT_LAYERS_DIR,
# BT_CACHE_DIR, BT_LXC_PATH, BT_SPEC, BT_KEEP, BT_NAME and BT_ROOTFS.
# Returns 0 when parsed, 2 after printing the usage, 1 on a bad argument
# (message on stderr).
bt_parse_args() {
    BT_APPLIANCE=""
    BT_TIMEOUT=$BT_DEFAULT_TIMEOUT
    BT_INTERVAL=$BT_DEFAULT_INTERVAL
    BT_BRIDGE=$BT_DEFAULT_BRIDGE
    BT_LAYERS_DIR=$BT_DEFAULT_LAYERS_DIR
    BT_CACHE_DIR=$BT_DEFAULT_CACHE_DIR
    BT_LXC_PATH=$BT_DEFAULT_LXC_PATH
    BT_NAME=""
    BT_SPEC=""
    BT_KEEP=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout|--interval)
                bt_is_positive_int "${2-}" || {
                    echo "boot-test: $1 needs a positive number of seconds" >&2
                    return 1
                }
                [ "$1" = --timeout ] && BT_TIMEOUT=$2 || BT_INTERVAL=$2
                shift
                ;;
            --bridge|--layers-dir|--cache-dir|--lxc-path|--name|--spec)
                [ -n "${2-}" ] || {
                    echo "boot-test: $1 needs a value" >&2
                    return 1
                }
                case "$1" in
                    --bridge) BT_BRIDGE=$2 ;;
                    --layers-dir) BT_LAYERS_DIR=$2 ;;
                    --cache-dir) BT_CACHE_DIR=$2 ;;
                    --lxc-path) BT_LXC_PATH=$2 ;;
                    --name) BT_NAME=$2 ;;
                    --spec) BT_SPEC=$2 ;;
                esac
                shift
                ;;
            --keep) BT_KEEP=1 ;;
            -h|--help)
                bt_usage
                return 2
                ;;
            -*)
                echo "boot-test: unknown option $1" >&2
                return 1
                ;;
            *)
                if [ -n "$BT_APPLIANCE" ]; then
                    echo "boot-test: one appliance at a time ($BT_APPLIANCE, $1)" >&2
                    return 1
                fi
                BT_APPLIANCE=$1
                ;;
        esac
        shift
    done
    if [ -z "$BT_APPLIANCE" ]; then
        echo "boot-test: APPLIANCE is required (core, nextcloud, ...)" >&2
        return 1
    fi
    if ! bt_is_appliance_name "$BT_APPLIANCE"; then
        echo "boot-test: '$BT_APPLIANCE' is not an appliance name (lower case, no keel- prefix)" >&2
        return 1
    fi
    BT_NAME=${BT_NAME:-$(bt_container_name "$BT_APPLIANCE")}
    if ! bt_is_container_name "$BT_NAME"; then
        echo "boot-test: '$BT_NAME' is not a container name (lower case, digits, dot, dash)" >&2
        return 1
    fi
    BT_ROOTFS=$BT_LXC_PATH/$BT_NAME/rootfs
    return 0
}

bt_is_global_ipv6() {
    # Global unicast, which includes ULA (fc00::/7); not link local
    # (fe80::/10), loopback or multicast. IPv4 has no colon.
    local addr=${1,,}
    [[ $addr == *:* ]] || return 1
    [[ $addr == fe[89ab]?:* ]] && return 1
    [[ $addr == ::1 ]] && return 1
    [[ $addr == ff* ]] && return 1
    return 0
}

bt_global_ipv6() {
    # stdin: the output of lxc-info -i ("IP:  ADDRESS" per line). Prints the
    # first global IPv6 address; returns 1 when there is none yet.
    local label addr _
    while read -r label addr _; do
        [ "$label" = "IP:" ] || continue
        if bt_is_global_ipv6 "$addr"; then
            printf '%s\n' "$addr"
            return 0
        fi
    done
    return 1
}

bt_container_ipv6() {
    # bt_container_ipv6 NAME LXCPATH: the container's first global IPv6.
    lxc-info -P "$2" -n "$1" -i 2>/dev/null | bt_global_ipv6
}

bt_now() {
    ${BT_CLOCK:-date +%s}
}

bt_deadline_passed() {
    # bt_deadline_passed START TIMEOUT NOW
    [ $(( $3 - $1 )) -ge "$2" ]
}

bt_wait_for() {
    # bt_wait_for TIMEOUT INTERVAL DESCRIPTION COMMAND [ARGS...]
    # Runs COMMAND until it succeeds; returns 1 once TIMEOUT seconds passed.
    local timeout=$1 interval=$2 what=$3 start now
    shift 3
    start=$(bt_now)
    until "$@"; do
        now=$(bt_now)
        if bt_deadline_passed "$start" "$timeout" "$now"; then
            echo "boot-test: timeout after ${timeout}s waiting for $what" >&2
            return 1
        fi
        ${BT_SLEEP:-sleep} "$interval"
    done
}

bt_is_ssh_banner() {
    [[ ${1-} == SSH-2.0-* ]]
}

bt_firstboot_done_in() {
    # bt_firstboot_done_in FILE: FILE is the rootfs copy of
    # /etc/default/inithooks; 98finalize sets RUN_FIRSTBOOT=false at the end.
    [ -r "$1" ] && grep -q '^RUN_FIRSTBOOT=false' "$1"
}

bt_lxc_config() {
    # bt_lxc_config NAME ROOTFS BRIDGE: an LXC config for a plain rootfs
    # directory on a bridge; the address comes from the bridge (SLAAC or
    # DHCPv6), the spec declares managed_by: host.
    #
    # The apparmor pair is not decoration. Under the stock container profile
    # a unit that asks systemd for a mount namespace is refused, and
    # mariadb.service, nginx.service and redis-server.service ask: they fail
    # with status=226/NAMESPACE, so the first boot never reaches the
    # database and the site never starts. A generated profile with nesting
    # allowed is what a container running systemd needs.
    cat <<CONFIG
lxc.uts.name = $1
lxc.rootfs.path = dir:$2
lxc.include = /usr/share/lxc/config/common.conf
lxc.arch = amd64
lxc.apparmor.profile = generated
lxc.apparmor.allow_nesting = 1
lxc.net.0.type = veth
lxc.net.0.link = $3
lxc.net.0.name = eth0
lxc.net.0.flags = up
lxc.start.auto = 0
CONFIG
}

bt_mark_container() {
    # bt_mark_container ROOTFS: make the tree look like the container build
    # buildtasks produces (its patches/container/conf):
    #
    #   the marker under /var/lib/turnkey-info, which inithooks' unit
    #   conditions read and which `keel inspect` reads to call the machine a
    #   container (network.managed_by: host),
    #
    #   REDIRECT_OUTPUT=true in /etc/default/inithooks, which sends first boot
    #   output to the log with a tail on the active console instead of writing
    #   it straight to tty1,
    #
    # and a drop-in that keeps the first boot off tty1. Nothing reads tty1 in
    # a container nobody has attached to, so a hook that prints more than the
    # terminal buffer holds blocks in the write and never returns
    # (keel-nodebb met that as a first boot that never came back).
    local rootfs=$1 defaults=$1/$BT_INITHOOKS_DEFAULT
    install -D -m 0644 /dev/null "$rootfs/$BT_CONTAINER_MARKER" || return 1
    if [ ! -f "$defaults" ]; then
        echo "boot-test: $defaults is not in the rootfs" >&2
        return 1
    fi
    sed -i '/REDIRECT_OUTPUT/ s/=.*/=true/' "$defaults" || return 1
    if ! grep -q '^REDIRECT_OUTPUT=true$' "$defaults"; then
        echo "boot-test: $defaults declares no REDIRECT_OUTPUT to set" >&2
        return 1
    fi
    install -D -m 0644 /dev/stdin "$rootfs/$BT_INITHOOKS_DROPIN" <<DROPIN || return 1
[Service]
StandardOutput=journal
StandardError=journal
DROPIN
}

bt_spec_targets() {
    # bt_spec_targets ROOTFS: the paths the spec is installed at.
    local relative
    for relative in $BT_SPEC_PATHS; do
        printf '%s/%s\n' "$1" "$relative"
    done
}

bt_spec_in_rootfs() {
    # bt_spec_in_rootfs SPEC ROOTFS: the spec with its secret references
    # pointed inside ROOTFS, printed on stdout. `keel spec apply` runs on
    # the host and resolves a secret path against the host, so the copy it
    # reads has to name the files this test wrote into the container.
    sed -E "s#^([[:space:]]*file:[[:space:]]*)(/etc/keel/secrets/)#\1$2\2#" "$1"
}

bt_random_password() {
    # A fixed block is read first and filtered afterwards. The other way
    # round, "tr < source | head -c N", leaves tr killed by SIGPIPE when
    # head has its N characters, and the set -o pipefail of boot-test.sh
    # turns that into exit 141 before the container is ever started.
    local pool source=${BT_RANDOM_SOURCE:-/dev/urandom}
    pool=$(head -c "$BT_RANDOM_BYTES" "$source" | LC_ALL=C tr -dc 'A-Za-z0-9')
    if [ "${#pool}" -lt "$BT_PASSWORD_LENGTH" ]; then
        echo "boot-test: $source gave only ${#pool} usable characters" >&2
        return 1
    fi
    printf '%s\n' "${pool:0:BT_PASSWORD_LENGTH}"
}

bt_secret_targets() {
    # bt_secret_targets ROOTFS: the secret files the spec references.
    local name
    for name in $BT_SECRETS; do
        printf '%s/etc/keel/secrets/%s\n' "$1" "$name"
    done
}

bt_status_verdict() {
    # bt_status_verdict WHAT WANT GOT: a route of the site answered the
    # status it must. What the site does is proved by what a request gets,
    # never by reading the nginx file that is supposed to say so.
    local what=$1 want=$2 got=${3-}
    if [ "$got" != "$want" ]; then
        echo "boot-test: $what answered $got, not $want" >&2
        return 1
    fi
    echo "boot-test: $what answered $want"
}

bt_json_flag() {
    # bt_json_flag TEXT KEY: the true or false value of KEY in a flat JSON
    # object (what status.php and `occ status --output=json` print), empty
    # when the key is not there. No JSON tool is needed on the runner.
    printf '%s' "${1-}" | tr -d ' \n' \
        | grep -o "\"$2\":\(true\|false\)" | head -1 | cut -d: -f2
}

bt_json_string() {
    # bt_json_string TEXT KEY: the string value of KEY, empty when not there.
    printf '%s' "${1-}" | tr -d '\n' \
        | grep -o "\"$2\": *\"[^\"]*\"" | head -1 | sed -E 's/^"[^"]*": *"//; s/"$//'
}

bt_nextcloud_state_verdict() {
    # bt_nextcloud_state_verdict WHAT TEXT: TEXT is what status.php or occ
    # status printed. The site is ready when it says installed, not in
    # maintenance, and no database upgrade waiting.
    local what=$1 text=${2-} installed maintenance upgrade
    installed=$(bt_json_flag "$text" installed)
    maintenance=$(bt_json_flag "$text" maintenance)
    upgrade=$(bt_json_flag "$text" needsDbUpgrade)
    if [ "$installed" != true ]; then
        echo "boot-test: $what does not say installed (installed: ${installed:-absent})" >&2
        return 1
    fi
    if [ "$maintenance" != false ]; then
        echo "boot-test: $what does not say out of maintenance (maintenance: ${maintenance:-absent})" >&2
        return 1
    fi
    if [ "$upgrade" != false ]; then
        echo "boot-test: $what does not say the database is current (needsDbUpgrade: ${upgrade:-absent})" >&2
        return 1
    fi
    echo "boot-test: $what says installed, not in maintenance, database current, version $(bt_json_string "$text" versionstring)"
}

bt_db_report_verdict() {
    # bt_db_report_verdict WHO REPORT LOGIN DB TABLE: REPORT is one row of
    # mysql --batch --skip-column-names: CURRENT_USER(), the count of the
    # schema DB and the count of the table TABLE in it. The account is LOGIN
    # (at any host) and it sees both.
    local who=$1 report=${2-} login=$3 db=$4 table=$5
    case "$report" in
        "$login"@*$'\t'1$'\t'1)
            echo "boot-test: $who logs in as ${report%%$'\t'*} and sees the $db database and its $table table"
            ;;
        *)
            echo "boot-test: $who: the database is not in the state the first boot should have left ($report)" >&2
            return 1
            ;;
    esac
}

bt_redis_verdict() {
    # bt_redis_verdict INFO CLASS: INFO is what `redis-cli -s SOCKET INFO
    # server` printed (the default user may run INFO only, by the ACL of
    # 40nextcloud), CLASS is what Nextcloud names for its file locks. Redis
    # answers when INFO has a redis_version line, and Nextcloud uses it
    # when the class is the Redis one.
    local info=${1-} class=${2-} version
    version=$(printf '%s\n' "$info" | tr -d '\r' | sed -n 's/^redis_version://p' | head -1)
    if [ -z "$version" ]; then
        echo "boot-test: Redis did not answer INFO on its socket" >&2
        return 1
    fi
    if [ "$class" != "$BT_REDIS_CLASS" ]; then
        echo "boot-test: Nextcloud names '${class}' for its file locks, not $BT_REDIS_CLASS" >&2
        return 1
    fi
    echo "boot-test: Redis $version answers on its socket, and Nextcloud uses it for its file locks"
}

bt_cron_verdict() {
    # bt_cron_verdict MODE TIMER_ENABLED SERVICE_LOAD SERVICE_ACTIVE: the
    # background jobs mode of Nextcloud (occ config:app:get core
    # backgroundjobs_mode), `systemctl is-enabled` of the timer, and the
    # LoadState and ActiveState of the service. The jobs run from the
    # units: mode cron, the timer enabled, the service loaded and not failed.
    local mode=${1-} enabled=${2-} load=${3-} active=${4-}
    if [ "$mode" != cron ]; then
        echo "boot-test: the background jobs mode is '$mode', not cron" >&2
        return 1
    fi
    if [ "$enabled" != enabled ]; then
        echo "boot-test: $BT_CRON_TIMER is '$enabled', not enabled" >&2
        return 1
    fi
    if [ "$load" != loaded ]; then
        echo "boot-test: $BT_CRON_SERVICE is '$load', not loaded" >&2
        return 1
    fi
    if [ "$active" = failed ]; then
        echo "boot-test: $BT_CRON_SERVICE is failed" >&2
        return 1
    fi
    echo "boot-test: background jobs mode cron, $BT_CRON_TIMER enabled, $BT_CRON_SERVICE loaded ($active)"
}

bt_diff_verdict() {
    # bt_diff_verdict CODE: interprets the exit code of keel diff
    # (docs/diff.md of the keel repository). 0 and 13 mean no drift.
    case "$1" in
        0) echo "keel diff: no drift"; return 0 ;;
        13) echo "keel diff: no drift, but a declared field could not be observed offline (see the report above)"; return 0 ;;
        14) echo "keel diff: drift found" >&2; return 1 ;;
        2|3) echo "keel diff: the spec is unreadable or invalid (exit $1)" >&2; return 1 ;;
        *) echo "keel diff: failed with exit $1" >&2; return 1 ;;
    esac
}
