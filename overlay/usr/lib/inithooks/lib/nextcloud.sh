#!/bin/bash
# Logic behind firstboot.d/40nextcloud and the gate of keel-nextcloud
# (decision 0004: logic apart from effect). Meant to be sourced. Every
# function reads its inputs from its arguments, prints its result on stdout
# and returns non-zero instead of exiting, so the caller decides what is
# fatal and a test can exercise every branch without a database, a web
# server, Redis, a network or root.
#
# No function here puts a secret on the command line of another process.
# The functions that handle one are shell functions, and a digest is made
# by printf (a builtin) into sha256sum on a pipe.
#
# The design is decision note 0086 of the handbook (proposed).

NEXTCLOUD_ROOT="${NEXTCLOUD_ROOT:-/var/www/nextcloud}"
NEXTCLOUD_CONFIG_DIR="${NEXTCLOUD_CONFIG_DIR:-$NEXTCLOUD_ROOT/config}"
NEXTCLOUD_CONFIG="${NEXTCLOUD_CONFIG:-$NEXTCLOUD_CONFIG_DIR/config.php}"
# The values that both nodes of a pair must hold: instanceid, secret,
# passwordsalt and the Redis account. Nextcloud reads every
# config/*.config.php after config.php, and the value of such a file wins
# (first test, 0086). Both nodes render the same file from the shared
# secrets, so neither copies anything from the other.
NEXTCLOUD_PAIR_CONFIG="${NEXTCLOUD_PAIR_CONFIG:-$NEXTCLOUD_CONFIG_DIR/keel-pair.config.php}"
NEXTCLOUD_DATA="${NEXTCLOUD_DATA:-/var/lib/nextcloud/data}"
# The log is outside the data directory: the data directory is a
# replicated path, and a write by a replica into it is a local change in
# the report of 0050. A log line can also hold a secret (first test).
NEXTCLOUD_LOG="${NEXTCLOUD_LOG:-/var/log/nextcloud/nextcloud.log}"
NEXTCLOUD_WEB_USER="${NEXTCLOUD_WEB_USER:-www-data}"
NEXTCLOUD_DB_NAME="${NEXTCLOUD_DB_NAME:-nextcloud}"
# The site logs in to MariaDB over the socket as the web user, with no
# password (unix_socket), as WordPress does: the seed of a replica copies
# the account with the rest of the primary.
NEXTCLOUD_DB_HOST="${NEXTCLOUD_DB_HOST:-localhost:/run/mysqld/mysqld.sock}"
NEXTCLOUD_ADMIN_USER="${NEXTCLOUD_ADMIN_USER:-admin}"
NEXTCLOUD_FALLBACK_DOMAIN="${NEXTCLOUD_FALLBACK_DOMAIN:-localhost}"
NEXTCLOUD_DB_SERVICE="${NEXTCLOUD_DB_SERVICE:-mariadb}"
NEXTCLOUD_SPEC="${NEXTCLOUD_SPEC:-/etc/keel/instance.yaml}"
NEXTCLOUD_ROLE_FILE="${NEXTCLOUD_ROLE_FILE:-/var/lib/keel/role}"
# Redis on its socket. The account "nextcloud" is the cache and the locks;
# "nextcloud-session" may touch the session keys only, because PHP prints
# session.save_path, with its password, in a warning when Redis is down
# (first test).
NEXTCLOUD_REDIS_SOCKET="${NEXTCLOUD_REDIS_SOCKET:-/run/redis/redis-server.sock}"
NEXTCLOUD_REDIS_USER="${NEXTCLOUD_REDIS_USER:-nextcloud}"
NEXTCLOUD_REDIS_SESSION_USER="${NEXTCLOUD_REDIS_SESSION_USER:-nextcloud-session}"
NEXTCLOUD_SESSION_PREFIX="${NEXTCLOUD_SESSION_PREFIX:-PHPREDIS_SESSION:}"
# The marks. READY: the first boot has made the site. OPEN: the gate lets
# requests through, because this node takes writes. nginx answers 503
# while OPEN is not there.
NEXTCLOUD_READY="${NEXTCLOUD_READY:-/var/lib/keel-nextcloud/ready}"
NEXTCLOUD_OPEN="${NEXTCLOUD_OPEN:-/run/keel-nextcloud/open}"
NEXTCLOUD_WAIT_TRIES="${NEXTCLOUD_WAIT_TRIES:-30}"
NEXTCLOUD_LOGIN_RE='^[A-Za-z0-9._@-]+$'
NEXTCLOUD_IDENT_RE='^[A-Za-z_][A-Za-z0-9_]*$'
NEXTCLOUD_DOMAIN_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'

# nextcloud_first_value VALUE...: the first argument that is set and is not
# the inithooks placeholder DEFAULT; fails when there is none.
nextcloud_first_value() {
    local value
    for value in "$@"; do
        if [[ -n "$value" && "${value^^}" != "DEFAULT" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    return 1
}

# nextcloud_admin_user [APP_ADMIN_USER]: the account of the administrator
nextcloud_admin_user() {
    local name
    name=$(nextcloud_first_value "${1-}" "$NEXTCLOUD_ADMIN_USER") || return 1
    [[ $name =~ $NEXTCLOUD_LOGIN_RE ]] || return 1
    printf '%s\n' "$name"
}

# nextcloud_db_name [APP_DB_NAME]: the schema Nextcloud owns. A name that
# would need quoting is refused, because it goes into a statement.
nextcloud_db_name() {
    local name
    name=$(nextcloud_first_value "${1-}" "$NEXTCLOUD_DB_NAME") || return 1
    [[ $name =~ $NEXTCLOUD_IDENT_RE ]] || return 1
    printf '%s\n' "$name"
}

# nextcloud_domain [APP_DOMAIN]: the host name of the site, from a domain
# or a URL. An empty value gives the fallback. A value that is not a host
# name fails.
nextcloud_domain() {
    local value
    value=$(nextcloud_first_value "${1-}" "$NEXTCLOUD_FALLBACK_DOMAIN") || return 1
    value=${value#http://}
    value=${value#https://}
    value=${value%%/*}
    [[ $value =~ $NEXTCLOUD_DOMAIN_RE ]] || return 1
    printf '%s\n' "${value,,}"
}

# nextcloud_spec_role [SPEC]: database.server.role of the instance
# description, or nothing when the file is missing or declares no role. A
# spec that exists and cannot be read as a mapping is an error, not "no
# role": a replica would then make a schema of its own.
nextcloud_spec_role() {
    local spec=${1:-$NEXTCLOUD_SPEC}
    [[ -e "$spec" ]] || return 0
    python3 - "$spec" <<'PY'
import sys, yaml

def mapping(value, name):
    if value is None:
        return {}
    if not isinstance(value, dict):
        sys.exit("%s is not a mapping" % name)
    return value

spec = mapping(yaml.safe_load(open(sys.argv[1])), "the spec")
server = mapping(mapping(spec.get("database"), "database").get("server"), "database.server")
print(server.get("role") or "")
PY
}

# nextcloud_is_replica ROLE READ_ONLY: true when this node must write
# nothing to the database. ROLE is what the description declares, and
# READ_ONLY is @@global.read_only of the server.
nextcloud_is_replica() {
    local role=${1-} read_only=${2-}
    [[ "$role" == replica ]] && return 0
    case "${read_only^^}" in
        1|ON) return 0 ;;
    esac
    return 1
}

# nextcloud_missing_values ROLE APP_PASS SECRET SALT REDIS_PASS SESSION_PASS:
# the names of the values that are not there, one per line. A replica needs
# no administrator password: the account comes with the copy of the
# primary. Every node needs the four shared secrets.
nextcloud_missing_values() {
    local role=${1-}
    [[ "$role" == replica || -n "${2-}" ]] || echo app_password
    [[ -n "${3-}" ]] || echo nextcloud_secret
    [[ -n "${4-}" ]] || echo nextcloud_passwordsalt
    [[ -n "${5-}" ]] || echo redis_password
    [[ -n "${6-}" ]] || echo redis_session_password
}

# nextcloud_instance_id SECRET: the instanceid of the pair, made from the
# shared secret, so both nodes get the same one with no copy. The name of
# the directory appdata_<instanceid> in the data directory follows it.
nextcloud_instance_id() {
    local secret=${1-} digest
    [[ -n "$secret" ]] || return 1
    digest=$(printf '%s' "$secret" | sha256sum) || return 1
    printf 'oc%s\n' "${digest:0:10}"
}

# nextcloud_php_quote VALUE: VALUE as a PHP string in single quotes
nextcloud_php_quote() {
    local value=${1-}
    value=${value//\\/\\\\}
    value=${value//\'/\\\'}
    printf "'%s'" "$value"
}

# nextcloud_pair_config_php SECRET SALT REDIS_PASS: the file
# keel-pair.config.php. It is the same on both nodes of a pair.
nextcloud_pair_config_php() {
    local secret=${1-} salt=${2-} redis_pass=${3-} instance
    [[ -n "$secret" && -n "$salt" && -n "$redis_pass" ]] || return 1
    instance=$(nextcloud_instance_id "$secret") || return 1
    cat <<EOF
<?php
// keel-nextcloud: the values both nodes of a pair hold (decision 0086).
// Written by the first boot from the shared secrets. A value here wins
// over config.php.
\$CONFIG = [
  'instanceid' => $(nextcloud_php_quote "$instance"),
  'secret' => $(nextcloud_php_quote "$secret"),
  'passwordsalt' => $(nextcloud_php_quote "$salt"),
  'memcache.local' => '\\OC\\Memcache\\APCu',
  'memcache.distributed' => '\\OC\\Memcache\\Redis',
  'memcache.locking' => '\\OC\\Memcache\\Redis',
  'redis' => [
    'host' => $(nextcloud_php_quote "$NEXTCLOUD_REDIS_SOCKET"),
    'port' => 0,
    'user' => $(nextcloud_php_quote "$NEXTCLOUD_REDIS_USER"),
    'password' => $(nextcloud_php_quote "$redis_pass"),
    'timeout' => 1.5,
  ],
];
EOF
}

# nextcloud_node_config_json DOMAIN ADDRESS...: the settings of this node
# for occ config:import. No secret is in them. The log level is 3 (errors):
# at level 2 Nextcloud logs the PHP warning that holds session.save_path
# with its password when Redis is down; at level 3 it does not (first test).
nextcloud_node_config_json() {
    local domain=${1-} address
    [[ -n "$domain" ]] || return 1
    shift
    local trusted="\"localhost\",\"$domain\""
    for address in "$@"; do
        [[ -n "$address" ]] || continue
        if [[ $address == *:* ]]; then
            trusted+=",\"[$address]\""
        else
            trusted+=",\"$address\""
        fi
    done
    cat <<EOF
{"system":{
 "trusted_domains":[$trusted],
 "overwrite.cli.url":"https://$domain",
 "datadirectory":"$NEXTCLOUD_DATA",
 "logfile":"$NEXTCLOUD_LOG",
 "log_type":"file",
 "loglevel":3,
 "apps_paths":[{"path":"$NEXTCLOUD_ROOT/apps","url":"/apps","writable":false},{"path":"$NEXTCLOUD_ROOT/custom_apps","url":"/custom_apps","writable":true}],
 "maintenance_window_start":4,
 "htaccess.RewriteBase":"/"
}}
EOF
}

# nextcloud_node_config_php DOMAIN ADDRESS...: the same settings as
# nextcloud_node_config_json, as entries of a PHP array, for the config.php
# of a replica. A replica cannot run occ config:import at its first boot:
# occ refuses to start while the data directory has not arrived from the
# primary (second test of 0086).
nextcloud_node_config_php() {
    local domain=${1-} address entry
    [[ -n "$domain" ]] || return 1
    shift
    entry="'localhost', $(nextcloud_php_quote "$domain")"
    for address in "$@"; do
        [[ -n "$address" ]] || continue
        if [[ $address == *:* ]]; then
            entry+=", $(nextcloud_php_quote "[$address]")"
        else
            entry+=", $(nextcloud_php_quote "$address")"
        fi
    done
    cat <<EOF
  'trusted_domains' => [$entry],
  'overwrite.cli.url' => $(nextcloud_php_quote "https://$domain"),
  'datadirectory' => $(nextcloud_php_quote "$NEXTCLOUD_DATA"),
  'logfile' => $(nextcloud_php_quote "$NEXTCLOUD_LOG"),
  'log_type' => 'file',
  'loglevel' => 3,
  'apps_paths' => [
    ['path' => $(nextcloud_php_quote "$NEXTCLOUD_ROOT/apps"), 'url' => '/apps', 'writable' => false],
    ['path' => $(nextcloud_php_quote "$NEXTCLOUD_ROOT/custom_apps"), 'url' => '/custom_apps', 'writable' => true],
  ],
  'maintenance_window_start' => 4,
  'htaccess.RewriteBase' => '/',
EOF
}

# nextcloud_redis_digest PASS: the SHA-256 of PASS, as Redis' ACL takes it
nextcloud_redis_digest() {
    local digest
    [[ -n "${1-}" ]] || return 1
    digest=$(printf '%s' "$1" | sha256sum) || return 1
    printf '%s\n' "${digest%% *}"
}

# nextcloud_redis_acl REDIS_PASS SESSION_PASS: the ACL lines of Redis. Each
# password is there as its digest only. The default user may run INFO and
# nothing else, as in keel-redis.
nextcloud_redis_acl() {
    local main session
    main=$(nextcloud_redis_digest "${1-}") || return 1
    session=$(nextcloud_redis_digest "${2-}") || return 1
    cat <<EOF
# keel-nextcloud: written by the first boot (decision 0086). Digests only.
user default on nopass -@all +info
user $NEXTCLOUD_REDIS_USER on #$main ~* &* +@all
user $NEXTCLOUD_REDIS_SESSION_USER on #$session resetkeys ~$NEXTCLOUD_SESSION_PREFIX* resetchannels -@all +get +set +setex +psetex +del +unlink +expire +pexpire +exists +ttl +pttl +eval +evalsha +script|load +hello +auth +select +ping +info
EOF
}

# nextcloud_session_pool SESSION_PASS: the PHP-FPM pool settings that put
# the PHP sessions in Redis as the session user.
nextcloud_session_pool() {
    local pass=${1-}
    [[ -n "$pass" ]] || return 1
    cat <<EOF
; keel-nextcloud: written by the first boot (decision 0086), mode 0600.
[www]
php_admin_value[session.save_handler] = redis
php_admin_value[session.save_path] = "unix://$NEXTCLOUD_REDIS_SOCKET?auth[user]=$NEXTCLOUD_REDIS_SESSION_USER&auth[pass]=$pass&database=0&prefix=$NEXTCLOUD_SESSION_PREFIX"
php_value[redis.session.locking_enabled] = 1
php_value[redis.session.lock_retries] = -1
php_value[redis.session.lock_wait_time] = 10000
env[PATH] = /usr/local/bin:/usr/bin:/bin
EOF
}

# nextcloud_gate READY ROLE_FILE_TEXT READ_ONLY: "open" when this node may
# serve, "closed" when it must not. Only a node that takes writes serves:
# a node with a read-only database cannot serve sync clients, not even for
# reads (first test), and its Redis is not the one of the writer.
#
# On a pair both must agree: keel's role file says role=primary, and the
# database takes writes. read_only alone is not enough: at a failover keel
# turns read_only off some seconds before it flips the Syncthing folders
# and writes the role file. The role file alone is not enough either: a
# primary that stopped hard still says role=primary when it boots, read
# only and fenced (second test). A node with no role file is standalone.
nextcloud_gate() {
    local ready=${1-} role_text=${2-} read_only=${3-}
    if [[ "$ready" != yes ]]; then
        echo closed
        return 0
    fi
    if [[ -n "$role_text" ]] && ! grep -qx 'role=primary' <<< "$role_text"; then
        echo closed
        return 0
    fi
    case "${read_only^^}" in
        0|OFF) echo open ;;
        *) echo closed ;;
    esac
}

# nextcloud_gate_action BEFORE AFTER: what the gate does when its answer
# goes from BEFORE to AFTER. "flush-open": the node has become the writer,
# so its Redis may hold a cache and locks from an earlier time, and it is
# emptied before the node serves. "close": the node stops. "none": no
# change.
nextcloud_gate_action() {
    local before=${1-} after=${2-}
    if [[ "$after" == open && "$before" != open ]]; then
        echo flush-open
    elif [[ "$after" != open && "$before" == open ]]; then
        echo close
    else
        echo none
    fi
}

# nextcloud_code_version VERSION_PHP: the version of the code tree, as
# config.php records it ("35.0.2.2"), read from version.php
nextcloud_code_version() {
    local file=${1-} line
    [[ -r "$file" ]] || return 1
    line=$(grep -o 'OC_Version = array([0-9, ]*)' "$file") || return 1
    line=${line#*(}
    line=${line%)}
    line=${line// /}
    [[ -n "$line" ]] || return 1
    printf '%s\n' "${line//,/.}"
}

# nextcloud_newest_core_migration DIR: the id of the newest migration of
# the core code (Version35000Date20260527162338.php gives
# 35000Date20260527162338)
nextcloud_newest_core_migration() {
    local dir=${1-} newest
    [[ -d "$dir" ]] || return 1
    newest=$(find "$dir" -maxdepth 1 -name 'Version*.php' -printf '%f\n' | sort | tail -n 1)
    [[ -n "$newest" ]] || return 1
    newest=${newest#Version}
    printf '%s\n' "${newest%.php}"
}

# nextcloud_follow_action CODE_VERSION CONFIG_VERSION MIGRATION_ROWS: what a
# replica does after the primary upgraded. MIGRATION_ROWS is the count of
# rows in oc_migrations for the newest core migration of the code. "set":
# the database is at the code, config.php is not, so the replica copies the
# version (first test: that is all it needs). "wait": the database is not
# there yet. "none": nothing to do.
nextcloud_follow_action() {
    local code=${1-} config=${2-} rows=${3-}
    [[ -n "$code" ]] || return 1
    if [[ "$code" == "$config" ]]; then
        echo none
    elif [[ "$rows" =~ ^[1-9][0-9]*$ ]]; then
        echo set
    else
        echo wait
    fi
}

# nextcloud_wait_ready COMMAND TRIES: run COMMAND (one word list) until it
# succeeds, at most TRIES times, one second apart
nextcloud_wait_ready() {
    local command=${1-} tries=${2-0} i
    for ((i = 0; i < tries; i++)); do
        # shellcheck disable=SC2086
        $command > /dev/null 2>&1 && return 0
        sleep "${NEXTCLOUD_WAIT_SLEEP:-1}"
    done
    return 1
}

# nextcloud_masked PASS: what a log may show of a password
nextcloud_masked() {
    local pass=${1-}
    printf '(%d characters)\n' "${#pass}"
}
