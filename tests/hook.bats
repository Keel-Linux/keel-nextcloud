#!/usr/bin/env bats
# Unit tests of overlay/usr/lib/inithooks/firstboot.d/40nextcloud, the first
# boot hook, executed for real against scratch directories.
#
# Everything it touches is a stub first in PATH (systemctl, mysqladmin,
# mysql, php, runuser, chown, openssl, hostname), each writing a line per
# call into a log the tests read. INITHOOKS_PATH is a scratch tree whose lib
# holds a symlink to the real library, so kcov measures the file the
# appliance ships. No test needs root, a database, Redis or a network.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    HOOK="$REPO/overlay/usr/lib/inithooks/firstboot.d/40nextcloud"
    SCRATCH="$BATS_TEST_TMPDIR"
    CALLS="$SCRATCH/calls"
    : > "$CALLS"

    IH="$SCRATCH/inithooks"
    mkdir -p "$IH/lib" "$IH/bin"
    # the dialog: what a person types at the console (NC_TEST_TYPED)
    cat > "$IH/bin/nextcloud.py" <<EOF
#!/bin/bash
echo "nextcloud.py \$*" >> "$CALLS"
echo "APP_PASS=\${NC_TEST_TYPED-typed-at-the-console}"
EOF
    chmod +x "$IH/bin/nextcloud.py"
    unset INITHOOKS_UNATTENDED
    ln -s "$(cd "$REPO/overlay/usr/lib/inithooks/lib" && pwd)/nextcloud.sh" "$IH/lib/nextcloud.sh"
    _console deferred

    DEFAULTS="$SCRATCH/default-inithooks"
    CONF="$SCRATCH/inithooks.conf"
    printf 'INITHOOKS_PATH=%s\nINITHOOKS_CONF=%s\n' "$IH" "$CONF" > "$DEFAULTS"

    NC="$SCRATCH/nextcloud"
    mkdir -p "$NC/config"
    printf '<?php\n$OC_Version = array(35,0,2,2);\n' > "$NC/version.php"

    STUBS="$SCRATCH/bin"
    mkdir -p "$STUBS"
    _stub systemctl 0
    _stub chown 0
    _stub mysqladmin 0
    cat > "$STUBS/openssl" <<EOF
#!/bin/bash
echo "openssl \$*" >> "$CALLS"
echo throwaway
EOF
    cat > "$STUBS/hostname" <<EOF
#!/bin/bash
echo "2804:db8::5 10.0.0.5"
EOF
    cat > "$STUBS/mysql" <<EOF
#!/bin/bash
echo "mysql \$*" >> "$CALLS"
case "\$*" in
    *read_only*) [ -n "\${NC_TEST_READ_FAILS:-}" ] && exit 1; echo \${NC_TEST_READ_ONLY:-0} ;;
    *"CREATE DATABASE"*) [ -n "\${NC_TEST_CREATE_FAILS:-}" ] && exit 1 ;;
    *"CREATE USER"*) [ -n "\${NC_TEST_ACCOUNT_FAILS:-}" ] && exit 1 ;;
esac
exit 0
EOF
    # runuser [--whitelist-environment=X] -u USER -- CMD...: log, then run CMD
    cat > "$STUBS/runuser" <<EOF
#!/bin/bash
echo "runuser \$*" >> "$CALLS"
while [ "\$1" != -- ]; do shift; done
shift
exec "\$@"
EOF
    # php: "php -l" and "php OCC ARGS". occ status says installed when
    # NC_TEST_INSTALLED is set; NC_TEST_FAIL names a subcommand that fails.
    cat > "$STUBS/php" <<EOF
#!/bin/bash
if [ "\$1" = -l ]; then
    echo "php -l \$2" >> "$CALLS"
    case "\$2" in *"\${NC_TEST_LINT_FAILS:-none}"*) exit 255 ;; esac
    exit 0
fi
shift
echo "occ \$*" >> "$CALLS"
[ "\${NC_TEST_FAIL:-}" = "\$1" ] && exit 1
case "\$1" in
    status) [ -n "\${NC_TEST_INSTALLED:-}" ] && echo '{"installed":true}' || echo '{"installed":false}' ;;
    config:import) cat > "$SCRATCH/imported.json" ;;
    user:resetpassword) echo "OC_PASS=\${OC_PASS-}" > "$SCRATCH/oc_pass" ;;
esac
exit 0
EOF
    chmod +x "$STUBS"/*
    PATH="$STUBS:$PATH"
    export PATH INITHOOKS_DEFAULT="$DEFAULTS"
    export NEXTCLOUD_ROOT="$NC" NEXTCLOUD_CONFIG_DIR="$NC/config"
    export NEXTCLOUD_CONFIG="$NC/config/config.php"
    export NEXTCLOUD_PAIR_CONFIG="$NC/config/keel-pair.config.php"
    export NEXTCLOUD_REDIS_ACL="$SCRATCH/acl.conf"
    export NEXTCLOUD_SESSION_POOL="$SCRATCH/pool.conf"
    export NEXTCLOUD_READY="$SCRATCH/state/ready"
    export NEXTCLOUD_SPEC="$SCRATCH/instance.yaml"
    export NEXTCLOUD_WAIT_TRIES=2 NEXTCLOUD_WAIT_SLEEP=0
    _conf
}

# _stub NAME CODE: a command that logs its call and exits CODE
_stub() {
    cat > "$STUBS/$1" <<EOF
#!/bin/bash
echo "$1 \$*" >> "$CALLS"
exit $2
EOF
    chmod +x "$STUBS/$1"
}

# _console MODE: the stand-in for inithooks' lib/console.sh. "deferred"
# has console_deferred, "skipped" has only console_skipped.
_console() {
    {
        echo 'console_unattended() { [[ -n "${INITHOOKS_UNATTENDED:-}" && "$INITHOOKS_UNATTENDED" != no ]]; }'
        echo "console_skipped() { echo \"skipped \$1: \$2\" >> '$CALLS'; }"
        if [ "$1" = deferred ]; then
            echo "console_deferred() { echo \"deferred \$1: \$2\" >> '$CALLS'; }"
        fi
    } > "$IH/lib/console.sh"
}

# _conf [NAME=VALUE...]: the inithooks.conf of the run, with every secret
# unless a test overrides or empties one
_conf() {
    {
        echo "APP_PASS=admin-secret-pass"
        echo "APP_DOMAIN=https://cloud.example.org"
        echo "KEEL_SECRET_NEXTCLOUD_SECRET=shared-secret"
        echo "KEEL_SECRET_NEXTCLOUD_PASSWORDSALT=shared-salt"
        echo "KEEL_SECRET_REDIS_PASSWORD=redis-main-pass"
        echo "KEEL_SECRET_REDIS_SESSION_PASSWORD=redis-session-pass"
        local kv
        for kv in "$@"; do echo "$kv"; done
    } > "$CONF"
}

@test "a primary: schema, install, password, node settings, cron, ready, gate" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "CREATE DATABASE IF NOT EXISTS \`nextcloud\`" "$CALLS"
    grep -q "IDENTIFIED VIA unix_socket" "$CALLS"
    grep -q "occ maintenance:install --database=mysql --database-name=nextcloud" "$CALLS"
    grep -q -- "--database-pass= --admin-user=admin --admin-pass=throwaway" "$CALLS"
    grep -q "occ user:resetpassword --password-from-env admin" "$CALLS"
    [ "$(cat "$SCRATCH/oc_pass")" = "OC_PASS=admin-secret-pass" ]
    grep -q "occ background:cron" "$CALLS"
    grep -q "systemctl enable --now keel-nextcloud-gate.timer keel-nextcloud-gate-watch.service" "$CALLS"
    [ -e "$NEXTCLOUD_READY" ]
    [[ "$output" == *"administrator 'admin' set from APP_PASS (17 characters)"* ]]
}

@test "no secret is an argument of any call" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    run ! grep -q -e admin-secret-pass -e shared-secret -e shared-salt -e redis-main-pass -e redis-session-pass "$CALLS"
}

@test "the pair file, the ACL and the pool are written with their modes" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "'secret' => 'shared-secret'" "$NEXTCLOUD_PAIR_CONFIG"
    grep -q "'passwordsalt' => 'shared-salt'" "$NEXTCLOUD_PAIR_CONFIG"
    [ "$(stat -c %a "$NEXTCLOUD_PAIR_CONFIG")" = 640 ]
    [ "$(stat -c %a "$NEXTCLOUD_REDIS_ACL")" = 640 ]
    [ "$(stat -c %a "$NEXTCLOUD_SESSION_POOL")" = 600 ]
    run ! grep -q redis-main-pass "$NEXTCLOUD_REDIS_ACL"
    grep -q "auth\[user\]=nextcloud-session&auth\[pass\]=redis-session-pass" "$NEXTCLOUD_SESSION_POOL"
    grep -q "chown root:redis" "$CALLS"
    grep -q "systemctl restart redis-server.service" "$CALLS"
    grep -q "systemctl restart php8.4-fpm.service" "$CALLS"
}

@test "the node settings carry the domain and the addresses of the node" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q '"cloud.example.org","\[2804:db8::5\]","10.0.0.5"' "$SCRATCH/imported.json"
}

@test "an installed site is left alone" {
    : > "$NEXTCLOUD_CONFIG"
    NC_TEST_INSTALLED=1 run "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
    run ! grep -q "maintenance:install" "$CALLS"
}

@test "a replica: a config.php at the version of the code, no database write" {
    printf 'database:\n  server:\n    role: replica\n' > "$NEXTCLOUD_SPEC"
    _conf APP_PASS=
    run "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"this node is a replica"* ]]
    grep -q "'version' => '35.0.2.2'" "$NEXTCLOUD_CONFIG"
    grep -q "'installed' => true" "$NEXTCLOUD_CONFIG"
    grep -q "'trusted_domains' => \['localhost', 'cloud.example.org', '\[2804:db8::5\]', '10.0.0.5'\]" "$NEXTCLOUD_CONFIG"
    run ! grep -q "config:import" "$CALLS"
    run ! grep -q "CREATE" "$CALLS"
    run ! grep -q "maintenance:install" "$CALLS"
    [ -e "$NEXTCLOUD_READY" ]
}

@test "a read-only server is a replica even with no role" {
    NC_TEST_READ_ONLY=1 run "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"read_only 1"* ]]
    run ! grep -q "CREATE" "$CALLS"
}

@test "a replica keeps a config.php that is already there" {
    echo keep > "$NEXTCLOUD_CONFIG"
    NC_TEST_READ_ONLY=1 run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "$NEXTCLOUD_CONFIG")" = keep ]
}

@test "a replica config.php that is not valid PHP is fatal" {
    NC_TEST_LINT_FAILS=config/config.php NC_TEST_READ_ONLY=1 run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"the config.php just written is not valid PHP"* ]]
}

@test "the primary removes the log that the install wrote into the data directory" {
    export NEXTCLOUD_DATA="$SCRATCH/data"
    mkdir -p "$NEXTCLOUD_DATA"
    : > "$NEXTCLOUD_DATA/nextcloud.log"
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ ! -e "$NEXTCLOUD_DATA/nextcloud.log" ]
}

@test "a replica fails when the code has no version" {
    printf '<?php\n' > "$NC/version.php"
    NC_TEST_READ_ONLY=1 run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot read the version of the code"* ]]
}

@test "missing secrets defer the hook and write nothing" {
    _conf KEEL_SECRET_REDIS_PASSWORD= APP_PASS=
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "deferred 40nextcloud: no app_password redis_password" "$CALLS"
    [ ! -e "$NEXTCLOUD_PAIR_CONFIG" ]
    run ! grep -q mysql "$CALLS"
}

@test "no administrator password and nobody at the console: deferred, nothing asked" {
    _conf APP_PASS=
    INITHOOKS_UNATTENDED=yes run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "deferred 40nextcloud: no app_password" "$CALLS"
    run ! grep -q "nextcloud.py" "$CALLS"
    [ ! -e "$NEXTCLOUD_PAIR_CONFIG" ]
}

@test "no administrator password and a person at the console: the dialog asks it" {
    _conf APP_PASS=
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "nextcloud.py APP_PASS" "$CALLS"
    [ "$(cat "$SCRATCH/oc_pass")" = "OC_PASS=typed-at-the-console" ]
}

@test "an empty answer at the console is fatal" {
    _conf APP_PASS=
    NC_TEST_TYPED= run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no password given"* ]]
}

@test "a missing shared secret is never asked, even at a console" {
    _conf APP_PASS= KEEL_SECRET_NEXTCLOUD_SECRET=
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "deferred 40nextcloud: no app_password nextcloud_secret" "$CALLS"
    run ! grep -q "nextcloud.py" "$CALLS"
}

@test "an inithooks without console_deferred records the hook as skipped" {
    _console skipped
    _conf KEEL_SECRET_NEXTCLOUD_SECRET=
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "skipped 40nextcloud: no nextcloud_secret" "$CALLS"
}

@test "a bad admin user, database name or domain is fatal" {
    _conf "APP_ADMIN_USER='a b'"
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not an account name"* ]]
    _conf "APP_DB_NAME='x-y'"
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a database name"* ]]
    _conf "APP_DOMAIN='bad_domain!'"
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a domain"* ]]
}

@test "a spec that cannot be read is fatal" {
    printf 'database: [1]\n' > "$NEXTCLOUD_SPEC"
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot read database.server.role"* ]]
}

@test "a pair file that is not valid PHP is fatal" {
    NC_TEST_LINT_FAILS=keel-pair run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not valid PHP"* ]]
}

@test "Redis or PHP-FPM that does not start is fatal" {
    cat > "$STUBS/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$CALLS"
for arg in "\$@"; do [ "\$arg" = "\${NC_TEST_UNIT_FAILS:-}" ] && exit 1; done
exit 0
EOF
    NC_TEST_UNIT_FAILS=redis-server.service run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"redis-server did not start"* ]]
    NC_TEST_UNIT_FAILS=php8.4-fpm.service run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"php8.4-fpm did not start"* ]]
    NC_TEST_UNIT_FAILS=keel-nextcloud-gate.timer run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot start keel-nextcloud-gate.timer and keel-nextcloud-gate-watch.service"* ]]
}

@test "a database that does not answer is fatal" {
    _stub mysqladmin 1
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"did not answer after 2 tries"* ]]
}

@test "read_only that cannot be read is fatal" {
    NC_TEST_READ_FAILS=1 run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot read @@global.read_only"* ]]
}

@test "a schema or an account that cannot be made is fatal" {
    NC_TEST_CREATE_FAILS=1 run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot create the database"* ]]
    NC_TEST_ACCOUNT_FAILS=1 run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"socket account"* ]]
}

@test "each failing occ step is fatal" {
    NC_TEST_FAIL=maintenance:install run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"occ maintenance:install failed"* ]]
    NC_TEST_FAIL=user:resetpassword run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot set the password"* ]]
    NC_TEST_FAIL=config:import run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"config:import"* ]]
    NC_TEST_FAIL=background:cron run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"background jobs"* ]]
}

@test "a file that cannot be given to its owner is fatal and leaves no temporary file" {
    _stub chown 1
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot give"* ]]
    [ -z "$(ls "$SCRATCH" | grep -E '^(acl|pool)\.conf\.')" ]
}

@test "a directory that cannot be written is fatal" {
    export NEXTCLOUD_REDIS_ACL="$SCRATCH/none/acl.conf"
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot write beside"* ]]
}

@test "a ready mark that cannot be written is fatal" {
    mkdir -p "$SCRATCH/state"
    export NEXTCLOUD_READY="$SCRATCH/state/ready"
    mkdir "$NEXTCLOUD_READY.d"
    export NEXTCLOUD_READY="$SCRATCH/state/ready.d"
    run "$HOOK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot write $NEXTCLOUD_READY"* ]]
}
