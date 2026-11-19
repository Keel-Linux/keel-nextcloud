#!/usr/bin/env bats
# Unit tests of overlay/usr/lib/keel-nextcloud/keel-nextcloud-cron, run for
# real against a scratch mark, with php, mysql, runuser and logger as stubs
# first in PATH.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    CRON="$REPO/overlay/usr/lib/keel-nextcloud/keel-nextcloud-cron"
    SCRATCH="$BATS_TEST_TMPDIR"
    CALLS="$SCRATCH/calls"
    : > "$CALLS"
    STUBS="$SCRATCH/bin"
    mkdir -p "$STUBS"
    # php -f cron.php: exits with NC_TEST_CRON_CODE (0 by default)
    cat > "$STUBS/php" <<EOF
#!/bin/bash
echo "php \$*" >> "$CALLS"
exit "\${NC_TEST_CRON_CODE:-0}"
EOF
    # mysql: read_only from NC_TEST_READ_ONLY ("fail": no answer)
    cat > "$STUBS/mysql" <<EOF
#!/bin/bash
echo "mysql \$*" >> "$CALLS"
[ "\${NC_TEST_READ_ONLY:-0}" = fail ] && exit 1
echo "\${NC_TEST_READ_ONLY:-0}"
EOF
    cat > "$STUBS/runuser" <<EOF
#!/bin/bash
echo "runuser \$*" >> "$CALLS"
while [ "\$1" != -- ]; do shift; done
shift
exec "\$@"
EOF
    cat > "$STUBS/logger" <<EOF
#!/bin/bash
echo "logger \$*" >> "$CALLS"
EOF
    chmod +x "$STUBS"/*
    export PATH="$STUBS:$PATH"
    export NEXTCLOUD_ROOT="$SCRATCH/nextcloud" NEXTCLOUD_OPEN="$SCRATCH/run/open"
    mkdir -p "$(dirname "$NEXTCLOUD_OPEN")"
    : > "$NEXTCLOUD_OPEN"
}

@test "a run that passes exits 0 and asks nothing of the database" {
    run "$CRON"
    [ "$status" -eq 0 ]
    grep -q "runuser -u www-data -- php -f $NEXTCLOUD_ROOT/cron.php" "$CALLS"
    run ! grep -q "mysql" "$CALLS"
    run ! grep -q "logger" "$CALLS"
}

@test "a run that fails on a database that became read-only exits 0 with one log line" {
    NC_TEST_CRON_CODE=1 NC_TEST_READ_ONLY=1 run "$CRON"
    [ "$status" -eq 0 ]
    grep -q "SELECT @@global.read_only" "$CALLS"
    [ "$(grep -c "^logger" "$CALLS")" -eq 1 ]
    grep -q "logger -t keel-nextcloud .*cron.php exited 1.*write role" "$CALLS"
}

@test "a run that fails after the gate removed the mark exits 0 with one log line" {
    rm -f "$NEXTCLOUD_OPEN"
    NC_TEST_CRON_CODE=1 run "$CRON"
    [ "$status" -eq 0 ]
    [ "$(grep -c "^logger" "$CALLS")" -eq 1 ]
    grep -q "logger -t keel-nextcloud .*write role" "$CALLS"
}

@test "a run that fails after the gate removed the mark exits 0 when the database does not answer" {
    rm -f "$NEXTCLOUD_OPEN"
    NC_TEST_CRON_CODE=1 NC_TEST_READ_ONLY=fail run "$CRON"
    [ "$status" -eq 0 ]
    grep -q "logger -t keel-nextcloud .*write role" "$CALLS"
}

@test "a run that fails on a node that still takes writes keeps the code of cron.php" {
    NC_TEST_CRON_CODE=3 NC_TEST_READ_ONLY=0 run "$CRON"
    [ "$status" -eq 3 ]
    run ! grep -q "logger" "$CALLS"
}

@test "a run that fails while the database does not answer and the mark is there keeps the failure" {
    NC_TEST_CRON_CODE=1 NC_TEST_READ_ONLY=fail run "$CRON"
    [ "$status" -eq 1 ]
    run ! grep -q "logger" "$CALLS"
}
