#!/usr/bin/env bats
# Unit tests of overlay/usr/lib/keel-nextcloud/keel-nextcloud-cron, run for
# real against a scratch mark, a scratch code tree and a scratch count, with
# php, mysql, redis-cli, runuser and logger as stubs first in PATH.
#
# The stubs of mysql and redis-cli know the time of the run: until the stub
# of php has run cron.php they answer the *_BEFORE values, after it the
# plain values. So a test can say "the database stopped during the run".

bats_require_minimum_version 1.5.0

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    CRON="$REPO/overlay/usr/lib/keel-nextcloud/keel-nextcloud-cron"
    UNIT="$REPO/overlay/etc/systemd/system/keel-nextcloud-cron.service"
    TIMER="$REPO/overlay/etc/systemd/system/keel-nextcloud-cron.timer"
    SCRATCH="$BATS_TEST_TMPDIR"
    CALLS="$SCRATCH/calls"
    RAN="$SCRATCH/ran"
    : > "$CALLS"
    STUBS="$SCRATCH/bin"
    mkdir -p "$STUBS"
    # php -f cron.php: exits with NC_TEST_CRON_CODE (0 by default).
    # php -r CODE CONFIG KEY: the value of KEY in config.php.
    cat > "$STUBS/php" <<EOF
#!/bin/bash
echo "php \$*" >> "$CALLS"
if [ "\$1" = -r ]; then
    case "\${@: -1}" in
        maintenance) echo "\${NC_TEST_MAINTENANCE-}" ;;
        version) echo "\${NC_TEST_CONFIG_VERSION:-35.0.2.2}" ;;
    esac
    exit 0
fi
: > "$RAN"
exit "\${NC_TEST_CRON_CODE:-0}"
EOF
    # mysql: read_only from NC_TEST_READ_ONLY ("fail": no answer), the
    # uptime of the server from NC_TEST_DB_UPTIME
    cat > "$STUBS/mysql" <<EOF
#!/bin/bash
echo "mysql \$*" >> "$CALLS"
if [ -e "$RAN" ]; then
    read_only="\${NC_TEST_READ_ONLY:-0}"
else
    read_only="\${NC_TEST_READ_ONLY_BEFORE:-0}"
fi
[ "\$read_only" = fail ] && exit 1
case "\$*" in
    *read_only*) echo "\$read_only" ;;
    *UPTIME*) echo "\${NC_TEST_DB_UPTIME:-86400}" ;;
esac
EOF
    # redis-cli -s SOCKET INFO server: NC_TEST_REDIS(_BEFORE) "down" gives
    # no answer; the lines end in CR LF, as Redis sends them
    cat > "$STUBS/redis-cli" <<EOF
#!/bin/bash
echo "redis-cli \$*" >> "$CALLS"
if [ -e "$RAN" ]; then
    redis="\${NC_TEST_REDIS:-ok}"
else
    redis="\${NC_TEST_REDIS_BEFORE:-ok}"
fi
if [ "\$redis" = down ]; then
    echo "Could not connect to Redis at /run/redis/redis-server.sock: No such file or directory"
    exit 1
fi
printf '# Server\\r\\nredis_version:8.0.2\\r\\nuptime_in_seconds:%s\\r\\n' "\${NC_TEST_REDIS_UPTIME:-86400}"
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
    export NEXTCLOUD_LIB="$REPO/overlay/usr/lib/inithooks/lib/nextcloud.sh"
    export NEXTCLOUD_ROOT="$SCRATCH/nextcloud" NEXTCLOUD_OPEN="$SCRATCH/run/open"
    export NEXTCLOUD_CONFIG="$NEXTCLOUD_ROOT/config/config.php"
    export NEXTCLOUD_CRON_FAILURES="$SCRATCH/run/cron-failures"
    mkdir -p "$(dirname "$NEXTCLOUD_OPEN")" "$NEXTCLOUD_ROOT/config"
    printf '<?php\n$OC_Version = array(35,0,2,2);\n' > "$NEXTCLOUD_ROOT/version.php"
    : > "$NEXTCLOUD_OPEN"
}

# the count of failures in a row the program holds, "none" with no file
count() {
    cat "$NEXTCLOUD_CRON_FAILURES" 2> /dev/null || echo none
}

@test "a run that passes asks the database and Redis first, runs cron.php and logs nothing" {
    run "$CRON"
    [ "$status" -eq 0 ]
    grep -q "SELECT @@global.read_only" "$CALLS"
    grep -q "redis-cli -s /run/redis/redis-server.sock INFO server" "$CALLS"
    grep -q "runuser -u www-data -- php -f $NEXTCLOUD_ROOT/cron.php" "$CALLS"
    run ! grep -q "logger" "$CALLS"
    [ "$(count)" = none ]
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

# Issue 7: the database stopped during the run, before the gate removed
# the mark (0.23.98 test: cron.php failed at 07:08:23, "MySQL server has
# gone away"; 0.23.100 test: failed at 18:40:26, the gate closed at
# 18:40:48). Before the fix the unit failed here and stayed failed while
# the database was down.
@test "a run that fails while the database does not answer and the mark is there ends cleanly and does not count" {
    echo 1 > "$NEXTCLOUD_CRON_FAILURES"
    NC_TEST_CRON_CODE=1 NC_TEST_READ_ONLY=fail run "$CRON"
    [ "$status" -eq 0 ]
    [ "$(grep -c "^logger" "$CALLS")" -eq 1 ]
    grep -q "logger -t keel-nextcloud -p user.notice cron.php exited 1: an outage cut the run (the database does not answer)" "$CALLS"
    [ "$(count)" = 1 ]
}

@test "a run that fails while Redis does not answer ends cleanly" {
    NC_TEST_CRON_CODE=1 NC_TEST_REDIS=down run "$CRON"
    [ "$status" -eq 0 ]
    grep -q "an outage cut the run (Redis does not answer)" "$CALLS"
    [ "$(count)" = none ]
}

@test "a run that fails after the database restarted during the run ends cleanly" {
    NC_TEST_CRON_CODE=1 NC_TEST_DB_UPTIME=0 run "$CRON"
    [ "$status" -eq 0 ]
    grep -q "an outage cut the run (the database started again during the run)" "$CALLS"
    [ "$(count)" = none ]
}

@test "a run that fails after Redis restarted during the run ends cleanly" {
    NC_TEST_CRON_CODE=1 NC_TEST_REDIS_UPTIME=0 run "$CRON"
    [ "$status" -eq 0 ]
    grep -q "an outage cut the run (Redis started again during the run)" "$CALLS"
}

@test "a run that fails while Nextcloud is in maintenance mode ends cleanly" {
    NC_TEST_CRON_CODE=1 NC_TEST_MAINTENANCE=1 run "$CRON"
    [ "$status" -eq 0 ]
    grep -q "an outage cut the run (Nextcloud is in maintenance mode)" "$CALLS"
}

@test "a run that fails while the code tree has no version.php ends cleanly" {
    rm -f "$NEXTCLOUD_ROOT/version.php"
    NC_TEST_CRON_CODE=255 run "$CRON"
    [ "$status" -eq 0 ]
    grep -q "cron.php exited 255: an outage cut the run (the code tree has no readable version.php: an upgrade of the image)" "$CALLS"
}

@test "a run that fails while the code and config.php are at other versions ends cleanly" {
    NC_TEST_CRON_CODE=1 NC_TEST_CONFIG_VERSION=35.0.1.1 run "$CRON"
    [ "$status" -eq 0 ]
    grep -q "an outage cut the run (the code is at 35.0.2.2 and config.php at 35.0.1.1: an upgrade)" "$CALLS"
}

@test "the database does not answer before the run: cron.php does not start and the count stays" {
    echo 2 > "$NEXTCLOUD_CRON_FAILURES"
    NC_TEST_READ_ONLY_BEFORE=fail run "$CRON"
    [ "$status" -eq 0 ]
    run ! grep -q "cron.php" <(grep -v "^logger" "$CALLS")
    [ "$(grep -c "^logger" "$CALLS")" -eq 1 ]
    grep -q "logger -t keel-nextcloud -p user.notice cron.php does not start: the database does not answer" "$CALLS"
    [ "$(count)" = 2 ]
}

@test "the database is read-only before the run: cron.php does not start" {
    NC_TEST_READ_ONLY_BEFORE=1 run "$CRON"
    [ "$status" -eq 0 ]
    run ! grep -q "php -f" "$CALLS"
    grep -q "cron.php does not start: the database is read-only" "$CALLS"
}

@test "Redis does not answer before the run: cron.php does not start" {
    NC_TEST_REDIS_BEFORE=down run "$CRON"
    [ "$status" -eq 0 ]
    run ! grep -q "php -f" "$CALLS"
    grep -q "cron.php does not start: Redis does not answer" "$CALLS"
}

@test "the first and the second failure with the database and Redis up end cleanly with a warning that counts" {
    NC_TEST_CRON_CODE=3 run "$CRON"
    [ "$status" -eq 0 ]
    grep -q "logger -t keel-nextcloud -p user.warning cron.php exited 3 with the database and Redis up: failure 1 of 3 in a row" "$CALLS"
    [ "$(count)" = 1 ]
    NC_TEST_CRON_CODE=3 run "$CRON"
    [ "$status" -eq 0 ]
    grep -q "failure 2 of 3 in a row" "$CALLS"
    [ "$(count)" = 2 ]
}

@test "the third failure in a row with the database and Redis up fails the unit with the code of cron.php" {
    echo 2 > "$NEXTCLOUD_CRON_FAILURES"
    NC_TEST_CRON_CODE=3 run "$CRON"
    [ "$status" -eq 3 ]
    grep -q "logger -t keel-nextcloud -p user.err cron.php exited 3 with the database and Redis up: failure 3 in a row, the unit fails" "$CALLS"
    [ "$(count)" = 3 ]
}

@test "each failure after the limit fails the unit again" {
    echo 5 > "$NEXTCLOUD_CRON_FAILURES"
    NC_TEST_CRON_CODE=1 run "$CRON"
    [ "$status" -eq 1 ]
    grep -q "failure 6 in a row, the unit fails" "$CALLS"
    [ "$(count)" = 6 ]
}

@test "the limit comes from NEXTCLOUD_CRON_FAILURE_LIMIT" {
    NEXTCLOUD_CRON_FAILURE_LIMIT=1 NC_TEST_CRON_CODE=1 run "$CRON"
    [ "$status" -eq 1 ]
    grep -q "failure 1 in a row, the unit fails" "$CALLS"
}

@test "a run that passes after failures clears the count and says so" {
    echo 2 > "$NEXTCLOUD_CRON_FAILURES"
    run "$CRON"
    [ "$status" -eq 0 ]
    [ "$(count)" = none ]
    grep -q "logger -t keel-nextcloud cron.php passes again after 2 failures in a row" "$CALLS"
}

@test "a count with bad content counts from zero" {
    echo "x y" > "$NEXTCLOUD_CRON_FAILURES"
    NC_TEST_CRON_CODE=1 run "$CRON"
    [ "$status" -eq 0 ]
    [ "$(count)" = 1 ]
}

@test "a count that cannot be written fails the unit at once" {
    : > "$SCRATCH/file"
    NEXTCLOUD_CRON_FAILURES="$SCRATCH/file/cron-failures" NC_TEST_CRON_CODE=4 run "$CRON"
    [ "$status" -eq 4 ]
    grep -q "logger -t keel-nextcloud -p user.err cron.php exited 4 and the count .* cannot be written: the unit fails" "$CALLS"
}

# (b) of issue 7: the unit runs again by itself at the next elapse. That
# holds while no dependency stops the timer or the unit, no Restart= starts
# the unit again in a storm, and the timer counts from the last start.
@test "the unit has no dependency that stops it, no Restart=, and keeps the condition of the gate" {
    run ! grep -Eq "^(Requires|BindsTo|PartOf|Requisite)=" "$UNIT"
    run ! grep -Eq "^Restart=" "$UNIT"
    grep -qx "ConditionPathExists=/run/keel-nextcloud/open" "$UNIT"
    grep -qx "Type=oneshot" "$UNIT"
    grep -qx "OnUnitActiveSec=5min" "$TIMER"
    run ! grep -Eq "^(Requires|BindsTo|PartOf|Requisite)=" "$TIMER"
}
