#!/usr/bin/env bats
# Unit tests of overlay/usr/lib/keel-nextcloud/keel-nextcloud-gate, run for
# real against scratch marks, with mysql, redis-cli, php, runuser and
# logger as stubs first in PATH.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    GATE="$REPO/overlay/usr/lib/keel-nextcloud/keel-nextcloud-gate"
    SCRATCH="$BATS_TEST_TMPDIR"
    CALLS="$SCRATCH/calls"
    : > "$CALLS"
    NC="$SCRATCH/nextcloud"
    mkdir -p "$NC/core/Migrations" "$NC/config"
    printf '<?php\n$OC_Version = array(35,0,2,2);\n' > "$NC/version.php"
    touch "$NC/core/Migrations/Version35000Date20260527162338.php"
    STUBS="$SCRATCH/bin"
    mkdir -p "$STUBS"
    # mysql: read_only from NC_TEST_READ_ONLY ("fail": no answer), and the
    # count of the core migration from NC_TEST_ROWS
    cat > "$STUBS/mysql" <<EOF
#!/bin/bash
echo "mysql \$*" >> "$CALLS"
case "\$*" in
    *read_only*) [ "\${NC_TEST_READ_ONLY:-0}" = fail ] && exit 1; echo "\${NC_TEST_READ_ONLY:-0}" ;;
    *oc_migrations*) [ "\${NC_TEST_ROWS:-1}" = fail ] && exit 1; echo "\${NC_TEST_ROWS:-1}" ;;
    *keel_settings*nextcloud_secret*) echo "\${NC_TEST_STORED_SECRET-pair-secret}" ;;
    *keel_settings*nextcloud_passwordsalt*) echo "\${NC_TEST_STORED_SALT-pair-salt}" ;;
esac
EOF
    cat > "$STUBS/redis-cli" <<EOF
#!/bin/bash
echo "redis-cli \$* auth=\${REDISCLI_AUTH:-none}" >> "$CALLS"
[ "\${NC_TEST_REDIS:-ok}" = down ] && { echo "Could not connect"; exit 1; }
[ "\${NC_TEST_REDIS:-ok}" = refuse ] && { echo "NOPERM"; exit 0; }
echo OK
EOF
    # php -r CODE FILE [KEY]: the stub answers what the gate asks of
    # config.php and of the pair file
    cat > "$STUBS/php" <<EOF
#!/bin/bash
if [ "\$1" = -r ]; then
    case "\$*" in
        *passwordsalt*) printf '%s\\n%s\\n' "\${NC_TEST_PAIR_SECRET:-pair-secret}" "\${NC_TEST_PAIR_SALT:-pair-salt}" ;;
        *redis*) echo redis-pass ;;
        *version*) echo "\${NC_TEST_CONFIG_VERSION:-35.0.2.2}" ;;
        *dbname*) echo "\${NC_TEST_DB_NAME:-nextcloud}" ;;
    esac
    exit 0
fi
shift
echo "occ \$*" >> "$CALLS"
[ -n "\${NC_TEST_OCC_FAILS:-}" ] && exit 1
exit 0
EOF
    cat > "$STUBS/runuser" <<EOF
#!/bin/bash
while [ "\$1" != -- ]; do shift; done
shift
exec "\$@"
EOF
    # ip -o address show to ADDRESS: one line when NC_TEST_VIP_HERE is set.
    # ip -o monitor address: two events, then the end of the stream.
    cat > "$STUBS/ip" <<EOF
#!/bin/bash
if [ "\$2" = monitor ]; then echo "Deleted 5: wg0 inet6 fd00::ffff:1/128"; echo "5: wg0 inet6 fd00::ffff:1/128"; exit 0; fi
[ -n "\${NC_TEST_VIP_HERE:-}" ] && echo "5: wg0    inet6 \$5/128 scope global"
exit 0
EOF
    cat > "$STUBS/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$CALLS"
[ -z "\${NC_TEST_RELOAD_FAILS:-}" ]
EOF
    cat > "$STUBS/chown" <<EOF
#!/bin/bash
echo "chown \$*" >> "$CALLS"
EOF
    cat > "$STUBS/logger" <<EOF
#!/bin/bash
echo "logger \$*" >> "$CALLS"
EOF
    chmod +x "$STUBS"/*
    export PATH="$STUBS:$PATH"
    export NEXTCLOUD_LIB="$REPO/overlay/usr/lib/inithooks/lib/nextcloud.sh"
    export NEXTCLOUD_ROOT="$NC" NEXTCLOUD_CONFIG="$NC/config/config.php"
    export NEXTCLOUD_PAIR_CONFIG="$NC/config/keel-pair.config.php"
    export NEXTCLOUD_READY="$SCRATCH/ready" NEXTCLOUD_OPEN="$SCRATCH/run/open"
    export NEXTCLOUD_ROLE_FILE="$SCRATCH/role"
    : > "$NEXTCLOUD_READY"
}

@test "a writable node that was closed empties Redis, then opens" {
    run "$GATE"
    [ "$status" -eq 0 ]
    grep -q "redis-cli --no-auth-warning --user nextcloud -s /run/redis/redis-server.sock FLUSHALL auth=redis-pass" "$CALLS"
    [ -e "$NEXTCLOUD_OPEN" ]
    grep -q "Redis emptied, the site is open" "$CALLS"
}

@test "an open writable node changes nothing" {
    mkdir -p "$(dirname "$NEXTCLOUD_OPEN")"
    : > "$NEXTCLOUD_OPEN"
    run "$GATE"
    [ "$status" -eq 0 ]
    run ! grep -q FLUSHALL "$CALLS"
    [ -e "$NEXTCLOUD_OPEN" ]
}

@test "a node whose database became read-only closes" {
    mkdir -p "$(dirname "$NEXTCLOUD_OPEN")"
    : > "$NEXTCLOUD_OPEN"
    NC_TEST_READ_ONLY=1 run "$GATE"
    [ "$status" -eq 0 ]
    [ ! -e "$NEXTCLOUD_OPEN" ]
    grep -q "the site is closed" "$CALLS"
}

@test "a node that keel says is a replica stays closed" {
    echo role=replica > "$NEXTCLOUD_ROLE_FILE"
    run "$GATE"
    [ "$status" -eq 0 ]
    [ ! -e "$NEXTCLOUD_OPEN" ]
    run ! grep -q FLUSHALL "$CALLS"
}

@test "a node before the end of its first boot stays closed" {
    rm -f "$NEXTCLOUD_READY"
    run "$GATE"
    [ "$status" -eq 0 ]
    [ ! -e "$NEXTCLOUD_OPEN" ]
    run ! grep -q "oc_migrations" "$CALLS"
}

@test "a database that does not answer closes the site and follows nothing" {
    mkdir -p "$(dirname "$NEXTCLOUD_OPEN")"
    : > "$NEXTCLOUD_OPEN"
    NC_TEST_READ_ONLY=fail run "$GATE"
    [ "$status" -eq 0 ]
    [ ! -e "$NEXTCLOUD_OPEN" ]
    run ! grep -q "oc_migrations" "$CALLS"
}

@test "Redis that does not answer keeps the site closed" {
    NC_TEST_REDIS=down run "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Redis did not answer"* ]]
    [ ! -e "$NEXTCLOUD_OPEN" ]
}

@test "Redis that refuses FLUSHALL keeps the site closed" {
    NC_TEST_REDIS=refuse run "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refused FLUSHALL"* ]]
    [ ! -e "$NEXTCLOUD_OPEN" ]
}

@test "an open mark that cannot be written keeps the site closed" {
    mkdir -p "$SCRATCH/run"
    chmod 0500 "$SCRATCH/run"
    run "$GATE"
    chmod 0700 "$SCRATCH/run"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot write"* ]]
}

@test "a primary with a VIP opens only while the VIP is on this node" {
    printf 'role=primary\nreplicates=database,files\nvip=fd00::ffff:1\n' > "$NEXTCLOUD_ROLE_FILE"
    run "$GATE" --state
    [ "$output" = closed ]
    NC_TEST_VIP_HERE=1 run "$GATE" --state
    [ "$output" = open ]
    NC_TEST_VIP_HERE=1 run "$GATE"
    [ -e "$NEXTCLOUD_OPEN" ]
    run "$GATE"
    [ ! -e "$NEXTCLOUD_OPEN" ]
}

@test "--watch runs one pass at the start and one at each address event" {
    run "$GATE" --watch
    [ "$status" -eq 0 ]
    [ "$(grep -c "read_only" "$CALLS")" -eq 3 ]
}

@test "--state prints the answer and changes nothing" {
    run "$GATE" --state
    [ "$output" = open ]
    [ ! -e "$NEXTCLOUD_OPEN" ]
    NC_TEST_READ_ONLY=1 run "$GATE" --state
    [ "$output" = closed ]
}

@test "a replica copies the version when the database is at the code" {
    NC_TEST_READ_ONLY=1 NC_TEST_CONFIG_VERSION=34.0.5.1 run "$GATE"
    [ "$status" -eq 0 ]
    grep -q "occ config:system:set version --value=35.0.2.2" "$CALLS"
    grep -q "the database is at 35.0.2.2" "$CALLS"
    grep -q "version='35000Date20260527162338'" "$CALLS"
}

@test "a replica waits while the database is not at the code" {
    NC_TEST_READ_ONLY=1 NC_TEST_CONFIG_VERSION=34.0.5.1 NC_TEST_ROWS=0 run "$GATE"
    [ "$status" -eq 0 ]
    run ! grep -q "config:system:set" "$CALLS"
}

@test "a replica at the version of the code does nothing" {
    NC_TEST_READ_ONLY=1 run "$GATE"
    [ "$status" -eq 0 ]
    run ! grep -q "config:system:set" "$CALLS"
}

@test "a replica that cannot set the version fails" {
    NC_TEST_READ_ONLY=1 NC_TEST_CONFIG_VERSION=34.0.5.1 NC_TEST_OCC_FAILS=1 run "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot set the version"* ]]
}

@test "a replica follows nothing with a bad database name, no migration, no code version or no count" {
    NC_TEST_READ_ONLY=1 NC_TEST_CONFIG_VERSION=34.0.5.1 NC_TEST_DB_NAME='x;y' run "$GATE"
    [ "$status" -eq 0 ]
    run ! grep -q "config:system:set" "$CALLS"
    NC_TEST_READ_ONLY=1 NC_TEST_CONFIG_VERSION=34.0.5.1 NC_TEST_ROWS=fail run "$GATE"
    [ "$status" -eq 0 ]
    run ! grep -q "config:system:set" "$CALLS"
    rm "$NC/core/Migrations/"*.php
    NC_TEST_READ_ONLY=1 NC_TEST_CONFIG_VERSION=34.0.5.1 run "$GATE"
    [ "$status" -eq 0 ]
    run ! grep -q "config:system:set" "$CALLS"
    rm "$NC/version.php"
    NC_TEST_READ_ONLY=1 NC_TEST_CONFIG_VERSION=34.0.5.1 run "$GATE"
    [ "$status" -eq 0 ]
    run ! grep -q "config:system:set" "$CALLS"
}

@test "before it opens, the gate writes the pair file from the stored rows and reloads PHP-FPM" {
    NC_TEST_STORED_SECRET=primary-secret NC_TEST_STORED_SALT=primary-salt run "$GATE"
    [ "$status" -eq 0 ]
    grep -q "'secret' => 'primary-secret'" "$NEXTCLOUD_PAIR_CONFIG"
    grep -q "'passwordsalt' => 'primary-salt'" "$NEXTCLOUD_PAIR_CONFIG"
    grep -q "'password' => 'redis-pass'" "$NEXTCLOUD_PAIR_CONFIG"
    [ "$(stat -c %a "$NEXTCLOUD_PAIR_CONFIG")" = 640 ]
    grep -q "chown root:www-data" "$CALLS"
    grep -q "systemctl reload php8.4-fpm.service" "$CALLS"
    grep -q "keel-pair.config.php now holds the secret and the salt of the database" "$CALLS"
    [ -e "$NEXTCLOUD_OPEN" ]
}

@test "a pair file that holds the stored rows is left alone" {
    run "$GATE"
    [ "$status" -eq 0 ]
    [ ! -e "$NEXTCLOUD_PAIR_CONFIG" ]
    run ! grep -q "systemctl reload" "$CALLS"
    [ -e "$NEXTCLOUD_OPEN" ]
}

@test "no stored row or a bad one: the pair file stays as it is" {
    NC_TEST_STORED_SECRET= run "$GATE"
    [ "$status" -eq 0 ]
    [ ! -e "$NEXTCLOUD_PAIR_CONFIG" ]
    [ -e "$NEXTCLOUD_OPEN" ]
    rm -f "$NEXTCLOUD_OPEN"
    NC_TEST_STORED_SECRET="it's" run "$GATE"
    [ "$status" -eq 0 ]
    [ ! -e "$NEXTCLOUD_PAIR_CONFIG" ]
    rm -f "$NEXTCLOUD_OPEN"
    NC_TEST_DB_NAME='x;y' NC_TEST_STORED_SECRET=other run "$GATE"
    [ "$status" -eq 0 ]
    [ ! -e "$NEXTCLOUD_PAIR_CONFIG" ]
}

@test "a pair file that cannot be written keeps the site closed" {
    export NEXTCLOUD_PAIR_CONFIG="$SCRATCH/none/keel-pair.config.php"
    NC_TEST_STORED_SECRET=other run "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot write beside"* ]]
    [ ! -e "$NEXTCLOUD_OPEN" ]
}

@test "PHP-FPM that does not reload keeps the site closed" {
    NC_TEST_STORED_SECRET=other NC_TEST_RELOAD_FAILS=1 run "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"php8.4-fpm did not reload"* ]]
    [ ! -e "$NEXTCLOUD_OPEN" ]
}

@test "a closed node follows the stored rows too" {
    NC_TEST_READ_ONLY=1 NC_TEST_STORED_SECRET=primary-secret run "$GATE"
    [ "$status" -eq 0 ]
    grep -q "'secret' => 'primary-secret'" "$NEXTCLOUD_PAIR_CONFIG"
    [ ! -e "$NEXTCLOUD_OPEN" ]
}
