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
esac
EOF
    cat > "$STUBS/redis-cli" <<EOF
#!/bin/bash
echo "redis-cli \$* auth=\${REDISCLI_AUTH:-none}" >> "$CALLS"
[ "\${NC_TEST_REDIS:-ok}" = down ] && { echo "Could not connect"; exit 1; }
[ "\${NC_TEST_REDIS:-ok}" = refuse ] && { echo "NOPERM"; exit 0; }
echo OK
EOF
    # php -r CODE FILE: the stub answers what the gate asks of config.php
    cat > "$STUBS/php" <<EOF
#!/bin/bash
if [ "\$1" = -r ]; then
    case "\$2" in
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
    # ip -o address show to ADDRESS: one line when NC_TEST_VIP_HERE is set
    cat > "$STUBS/ip" <<EOF
#!/bin/bash
[ -n "\${NC_TEST_VIP_HERE:-}" ] && echo "5: wg0    inet6 \$5/128 scope global"
exit 0
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
    ! grep -q FLUSHALL "$CALLS"
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
    ! grep -q FLUSHALL "$CALLS"
}

@test "a node before the end of its first boot stays closed" {
    rm -f "$NEXTCLOUD_READY"
    run "$GATE"
    [ "$status" -eq 0 ]
    [ ! -e "$NEXTCLOUD_OPEN" ]
    ! grep -q "oc_migrations" "$CALLS"
}

@test "a database that does not answer closes the site and follows nothing" {
    mkdir -p "$(dirname "$NEXTCLOUD_OPEN")"
    : > "$NEXTCLOUD_OPEN"
    NC_TEST_READ_ONLY=fail run "$GATE"
    [ "$status" -eq 0 ]
    [ ! -e "$NEXTCLOUD_OPEN" ]
    ! grep -q "oc_migrations" "$CALLS"
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
    ! grep -q "config:system:set" "$CALLS"
}

@test "a replica at the version of the code does nothing" {
    NC_TEST_READ_ONLY=1 run "$GATE"
    [ "$status" -eq 0 ]
    ! grep -q "config:system:set" "$CALLS"
}

@test "a replica that cannot set the version fails" {
    NC_TEST_READ_ONLY=1 NC_TEST_CONFIG_VERSION=34.0.5.1 NC_TEST_OCC_FAILS=1 run "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot set the version"* ]]
}

@test "a replica follows nothing with a bad database name, no migration, no code version or no count" {
    NC_TEST_READ_ONLY=1 NC_TEST_CONFIG_VERSION=34.0.5.1 NC_TEST_DB_NAME='x;y' run "$GATE"
    [ "$status" -eq 0 ]
    ! grep -q "config:system:set" "$CALLS"
    NC_TEST_READ_ONLY=1 NC_TEST_CONFIG_VERSION=34.0.5.1 NC_TEST_ROWS=fail run "$GATE"
    [ "$status" -eq 0 ]
    ! grep -q "config:system:set" "$CALLS"
    rm "$NC/core/Migrations/"*.php
    NC_TEST_READ_ONLY=1 NC_TEST_CONFIG_VERSION=34.0.5.1 run "$GATE"
    [ "$status" -eq 0 ]
    ! grep -q "config:system:set" "$CALLS"
    rm "$NC/version.php"
    NC_TEST_READ_ONLY=1 NC_TEST_CONFIG_VERSION=34.0.5.1 run "$GATE"
    [ "$status" -eq 0 ]
    ! grep -q "config:system:set" "$CALLS"
}
