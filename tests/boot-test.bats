#!/usr/bin/env bats
# Unit tests of tests/lib/boot-test-lib.sh: argument parsing, address
# discovery from lxc-info, waiting with a deadline, the secret files, the
# verdicts on status.php, occ, the database, Redis and the background jobs,
# and the diff verdict. Nothing here needs root, a network or
# LXC: lxc-info is a stub first in PATH, the clock and sleep are functions.

bats_require_minimum_version 1.5.0

setup() {
    load lib/boot-test-lib.sh
    STUBS=$(mktemp -d)
    PATH=$STUBS:$PATH
}

teardown() {
    rm -rf "$STUBS"
}

stub_lxc_info() {
    # stub_lxc_info OUTPUT: lxc-info prints OUTPUT and records its arguments
    printf '#!/bin/bash\necho "$*" >> "%s/lxc-info.calls"\ncat <<"OUT"\n%s\nOUT\n' "$STUBS" "$1" > "$STUBS/lxc-info"
    chmod +x "$STUBS/lxc-info"
}

# argument parsing

@test "parse_args: the appliance alone takes every default" {
    bt_parse_args nextcloud
    [ "$BT_APPLIANCE" = nextcloud ]
    [ "$BT_TIMEOUT" = 900 ]
    [ "$BT_INTERVAL" = 5 ]
    [ "$BT_BRIDGE" = lxcbr0 ]
    [ "$BT_LAYERS_DIR" = /mnt/builds/layers ]
    [ "$BT_CACHE_DIR" = /var/cache/keel/layers ]
    [ "$BT_LXC_PATH" = /var/lib/lxc ]
    [ -z "$BT_SPEC" ]
    [ "$BT_KEEP" = 0 ]
    [ "$BT_NAME" = keel-nextcloud-boot-test ]
    [ "$BT_ROOTFS" = /var/lib/lxc/keel-nextcloud-boot-test/rootfs ]
}

@test "parse_args: every option is read" {
    bt_parse_args --timeout 60 --interval 2 --bridge br7 --layers-dir /l \
        --cache-dir /c --lxc-path /x --name lamp-run-7 --spec /s.yaml --keep lamp
    [ "$BT_APPLIANCE" = lamp ]
    [ "$BT_TIMEOUT" = 60 ]
    [ "$BT_INTERVAL" = 2 ]
    [ "$BT_BRIDGE" = br7 ]
    [ "$BT_LAYERS_DIR" = /l ]
    [ "$BT_CACHE_DIR" = /c ]
    [ "$BT_LXC_PATH" = /x ]
    [ "$BT_SPEC" = /s.yaml ]
    [ "$BT_KEEP" = 1 ]
    [ "$BT_NAME" = lamp-run-7 ]
    [ "$BT_ROOTFS" = /x/lamp-run-7/rootfs ]
}

@test "parse_args: --name is checked as a container name" {
    run bt_parse_args nextcloud --name "Run 7"
    [ "$status" -eq 1 ]
    [[ $output == *"is not a container name"* ]]
    run bt_parse_args nextcloud --name -lead
    [ "$status" -eq 1 ]
}

@test "is_container_name" {
    bt_is_container_name keel-nextcloud-ci-36255612491-1
    bt_is_container_name 7
    run ! bt_is_container_name "keel core"
    run ! bt_is_container_name -x
    run ! bt_is_container_name ""
}

@test "parse_args: the appliance is required" {
    run bt_parse_args --keep
    [ "$status" -eq 1 ]
    [[ $output == *"APPLIANCE is required"* ]]
}

@test "parse_args: one appliance at a time" {
    run bt_parse_args nextcloud lamp
    [ "$status" -eq 1 ]
    [[ $output == *"one appliance at a time"* ]]
}

@test "parse_args: the keel- prefix and upper case are rejected" {
    run bt_parse_args keel-nextcloud
    [ "$status" -eq 1 ]
    [[ $output == *"not an appliance name"* ]]
    run bt_parse_args Nextcloud
    [ "$status" -eq 1 ]
}

@test "parse_args: an unknown option fails" {
    run bt_parse_args nextcloud --verbose
    [ "$status" -eq 1 ]
    [[ $output == *"unknown option --verbose"* ]]
}

@test "parse_args: timeout and interval must be positive integers" {
    run bt_parse_args nextcloud --timeout 0
    [ "$status" -eq 1 ]
    [[ $output == *"--timeout needs a positive number"* ]]
    run bt_parse_args nextcloud --interval abc
    [ "$status" -eq 1 ]
    run bt_parse_args nextcloud --timeout
    [ "$status" -eq 1 ]
}

@test "parse_args: an option with a value refuses an empty one" {
    run bt_parse_args nextcloud --bridge
    [ "$status" -eq 1 ]
    [[ $output == *"--bridge needs a value"* ]]
    run bt_parse_args nextcloud --spec ""
    [ "$status" -eq 1 ]
}

@test "parse_args: --help prints the usage and returns 2" {
    run bt_parse_args --help
    [ "$status" -eq 2 ]
    [[ ${lines[0]} == "usage: tests/boot-test.sh APPLIANCE"* ]]
    [[ $output == *"--keep"* ]]
    run bt_parse_args -h
    [ "$status" -eq 2 ]
}

@test "is_positive_int and is_appliance_name" {
    bt_is_positive_int 1
    bt_is_positive_int 900
    run ! bt_is_positive_int 0
    run ! bt_is_positive_int 07
    run ! bt_is_positive_int -5
    run ! bt_is_positive_int ""
    bt_is_appliance_name nginx-php-fastcgi
    run ! bt_is_appliance_name keel-core
    run ! bt_is_appliance_name 9core
    run ! bt_is_appliance_name ""
}

# address discovery

@test "is_global_ipv6: global and ULA yes, link local, loopback, multicast, IPv4 no" {
    bt_is_global_ipv6 2001:db8:1::10
    bt_is_global_ipv6 fd00:1::10
    bt_is_global_ipv6 2001:DB8::1
    run ! bt_is_global_ipv6 fe80::216:3eff:fe00:1
    run ! bt_is_global_ipv6 FEBF::1
    run ! bt_is_global_ipv6 ::1
    run ! bt_is_global_ipv6 ff02::1
    run ! bt_is_global_ipv6 192.0.2.10
    run ! bt_is_global_ipv6 ""
}

@test "global_ipv6: picks the first global address out of lxc-info output" {
    output=$(printf 'IP:             fe80::216:3eff:fe00:1\nIP:             192.0.2.10\nIP:             2001:db8:1::10\nIP:             2001:db8:1::11\n' | bt_global_ipv6)
    [ "$output" = 2001:db8:1::10 ]
}

@test "global_ipv6: ignores lines that are not addresses" {
    output=$(printf 'Name:           keel-nextcloud-boot-test\nState:          RUNNING\nPID:            4242\nIP:             fd00::10\nLink:           veth0\n' | bt_global_ipv6)
    [ "$output" = fd00::10 ]
}

@test "global_ipv6: returns 1 while only link local or IPv4 addresses exist" {
    run bt_global_ipv6 <<< $'IP:             fe80::1\nIP:             192.0.2.10'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run bt_global_ipv6 < /dev/null
    [ "$status" -eq 1 ]
}

@test "container_ipv6: calls lxc-info with the lxcpath and the name" {
    stub_lxc_info $'Name:           keel-nextcloud-boot-test\nIP:             fe80::1\nIP:             2001:db8:1::10'
    output=$(bt_container_ipv6 keel-nextcloud-boot-test /var/lib/lxc)
    [ "$output" = 2001:db8:1::10 ]
    [ "$(cat "$STUBS/lxc-info.calls")" = "-P /var/lib/lxc -n keel-nextcloud-boot-test -i" ]
}

@test "container_ipv6: fails when lxc-info has no global address yet" {
    stub_lxc_info $'Name:           keel-nextcloud-boot-test\nState:          RUNNING'
    run bt_container_ipv6 keel-nextcloud-boot-test /var/lib/lxc
    [ "$status" -eq 1 ]
}

# timeouts

fake_clock() { echo "$FAKE_NOW"; }
fake_sleep() { FAKE_NOW=$(( FAKE_NOW + $1 )); echo "sleep $1" >> "$STUBS/sleeps"; }
succeed_on_third() { CALLS=$(( CALLS + 1 )); [ "$CALLS" -ge 3 ]; }
never() { return 1; }

@test "deadline_passed" {
    run ! bt_deadline_passed 100 30 129
    bt_deadline_passed 100 30 130
    bt_deadline_passed 100 30 500
}

@test "now: the default clock is epoch seconds and BT_CLOCK replaces it" {
    [[ $(bt_now) =~ ^[0-9]{10}$ ]]
    BT_CLOCK=fake_clock FAKE_NOW=42
    [ "$(bt_now)" = 42 ]
}

@test "wait_for: polls at the interval until the command succeeds" {
    BT_CLOCK=fake_clock BT_SLEEP=fake_sleep FAKE_NOW=1000 CALLS=0
    bt_wait_for 60 5 "three calls" succeed_on_third
    [ "$CALLS" -eq 3 ]
    [ "$(cat "$STUBS/sleeps")" = $'sleep 5\nsleep 5' ]
}

@test "wait_for: gives up with a message once the timeout has passed" {
    # shellcheck disable=SC2034  # read by bt_now and bt_wait_for
    BT_CLOCK=fake_clock BT_SLEEP=fake_sleep FAKE_NOW=1000
    run bt_wait_for 12 5 "something that never happens" never
    [ "$status" -eq 1 ]
    [[ $output == *"timeout after 12s waiting for something that never happens"* ]]
    [ "$(wc -l < "$STUBS/sleeps")" -eq 3 ]
}

# readiness and verdicts

@test "is_ssh_banner" {
    bt_is_ssh_banner "SSH-2.0-OpenSSH_10.0p2 Debian-7"
    run ! bt_is_ssh_banner "HTTP/1.1 400 Bad Request"
    run ! bt_is_ssh_banner ""
}

@test "firstboot_done_in: RUN_FIRSTBOOT=false in the rootfs copy of /etc/default/inithooks" {
    printf 'INITHOOKS_CONF=/etc/inithooks.conf\nRUN_FIRSTBOOT=false\n' > "$STUBS/done"
    printf 'RUN_FIRSTBOOT=true\n' > "$STUBS/pending"
    bt_firstboot_done_in "$STUBS/done"
    run ! bt_firstboot_done_in "$STUBS/pending"
    run ! bt_firstboot_done_in "$STUBS/missing"
}

@test "lxc_config: names the container, the rootfs and the bridge" {
    output=$(bt_lxc_config keel-nextcloud-boot-test /var/lib/lxc/keel-nextcloud-boot-test/rootfs br0)
    [[ $output == *"lxc.uts.name = keel-nextcloud-boot-test"* ]]
    [[ $output == *"lxc.rootfs.path = dir:/var/lib/lxc/keel-nextcloud-boot-test/rootfs"* ]]
    [[ $output == *"lxc.net.0.link = br0"* ]]
    [[ $output == *"lxc.net.0.type = veth"* ]]
}

@test "lxc_config: asks for the apparmor profile a unit with a namespace needs" {
    output=$(bt_lxc_config keel-nextcloud-boot-test /var/lib/lxc/keel-nextcloud-boot-test/rootfs br0)
    [[ $output == *"lxc.apparmor.profile = generated"* ]]
    [[ $output == *"lxc.apparmor.allow_nesting = 1"* ]]
}

fake_rootfs() {
    # fake_rootfs [VALUE]: a scratch rootfs with an inithooks defaults file,
    # REDIRECT_OUTPUT set to VALUE (default false), printed on stdout
    local rootfs="$BATS_TEST_TMPDIR/rootfs-$RANDOM"
    mkdir -p "$rootfs/etc/default"
    cat > "$rootfs/$BT_INITHOOKS_DEFAULT" <<DEF
INITHOOKS_CONF=/etc/inithooks.conf
RUN_FIRSTBOOT=true
REDIRECT_OUTPUT=${1-false}
SUDOADMIN=false
DEF
    printf '%s\n' "$rootfs"
}

@test "mark_container: writes the marker the unit conditions and inspect read" {
    rootfs=$(fake_rootfs)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    [ -f "$rootfs/var/lib/turnkey-info/inithooks.service/lxc" ]
}

@test "mark_container: turns REDIRECT_OUTPUT on, so no hook blocks writing to tty1" {
    rootfs=$(fake_rootfs false)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    grep -q '^REDIRECT_OUTPUT=true$' "$rootfs/$BT_INITHOOKS_DEFAULT"
    # the rest of the file is left alone
    grep -q '^RUN_FIRSTBOOT=true$' "$rootfs/$BT_INITHOOKS_DEFAULT"
    grep -q '^SUDOADMIN=false$' "$rootfs/$BT_INITHOOKS_DEFAULT"
}

@test "mark_container: takes the first boot off tty1 with a systemd drop-in" {
    rootfs=$(fake_rootfs)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    dropin="$rootfs/$BT_INITHOOKS_DROPIN"
    [ -f "$dropin" ]
    grep -q '^\[Service\]$' "$dropin"
    grep -q '^StandardOutput=journal$' "$dropin"
    grep -q '^StandardError=journal$' "$dropin"
}

@test "mark_container: a tree that already redirects is left redirecting" {
    rootfs=$(fake_rootfs true)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^REDIRECT_OUTPUT=true$' "$rootfs/$BT_INITHOOKS_DEFAULT")" -eq 1 ]
}

@test "mark_container: a rootfs with no inithooks defaults fails loudly" {
    rootfs="$BATS_TEST_TMPDIR/bare"
    mkdir -p "$rootfs"
    run bt_mark_container "$rootfs"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not in the rootfs"* ]]
}

@test "mark_container: defaults that declare no REDIRECT_OUTPUT fail loudly" {
    rootfs=$(fake_rootfs)
    grep -v REDIRECT_OUTPUT "$rootfs/$BT_INITHOOKS_DEFAULT" > "$rootfs/trimmed"
    mv "$rootfs/trimmed" "$rootfs/$BT_INITHOOKS_DEFAULT"
    run bt_mark_container "$rootfs"
    [ "$status" -eq 1 ]
    [[ "$output" == *"declares no REDIRECT_OUTPUT"* ]]
}

@test "spec_targets: both paths the first boot reads, under the rootfs" {
    output=$(bt_spec_targets /r)
    [ "$output" = $'/r/etc/keel/instance.yaml\n/r/etc/inithooks.yaml' ]
}

@test "secret_targets: the three secret files the spec references" {
    output=$(bt_secret_targets /r)
    [ "$output" = $'/r/etc/keel/secrets/root_password\n/r/etc/keel/secrets/db_password\n/r/etc/keel/secrets/app_password' ]
}

@test "spec_in_rootfs: secret references are pointed inside the rootfs" {
    printf 'secrets:\n  root_password:\n    file: /etc/keel/secrets/root_password\ntls:\n  acme:\n    enabled: false\n' > "$STUBS/spec"
    output=$(bt_spec_in_rootfs "$STUBS/spec" /r/rootfs)
    [[ $output == *"file: /r/rootfs/etc/keel/secrets/root_password"* ]]
    [[ $output == *"enabled: false"* ]]
    [[ $output != *"file: /etc/keel"* ]]
}

@test "random_password: 24 alphanumeric characters from the random source" {
    output=$(bt_random_password)
    [[ $output =~ ^[A-Za-z0-9]{24}$ ]]
    printf 'ab!!cd%%%%efghijklmnopqrstuvwxyz0123456789' > "$STUBS/random"
    output=$(BT_RANDOM_SOURCE=$STUBS/random bt_random_password)
    [ "$output" = abcdefghijklmnopqrstuvwx ]
}

@test "random_password: a source too poor to fill the password fails loudly" {
    printf '!!!!short!!!!' > "$STUBS/poor"
    BT_RANDOM_SOURCE="$STUBS/poor"
    run bt_random_password
    [ "$status" -eq 1 ]
    [[ $output == *"gave only 5 usable characters"* ]]
}

@test "diff_verdict: 0 and 13 pass, everything else fails with a message" {
    run bt_diff_verdict 0
    [ "$status" -eq 0 ]
    [ "$output" = "keel diff: no drift" ]
    run bt_diff_verdict 13
    [ "$status" -eq 0 ]
    [[ $output == *"could not be observed offline"* ]]
    run bt_diff_verdict 14
    [ "$status" -eq 1 ]
    [[ $output == *"drift found"* ]]
    run bt_diff_verdict 2
    [ "$status" -eq 1 ]
    [[ $output == *"unreadable or invalid (exit 2)"* ]]
    run bt_diff_verdict 3
    [ "$status" -eq 1 ]
    run bt_diff_verdict 127
    [ "$status" -eq 1 ]
    [[ $output == *"failed with exit 127"* ]]
}

@test "fence_verdict: the fence down and no fence rule in the ruleset pass" {
    run bt_fence_verdict disabled 0 0.23.105
    [ "$status" -eq 0 ]
    [[ $output == *"the init fence is down, and keel's ruleset holds no rule of it"* ]]
}

@test "fence_verdict: a fence still enabled after the first boot fails" {
    run bt_fence_verdict enabled 1 0.23.105
    [ "$status" -eq 1 ]
    [[ $output == *"turnkey-init-fence.service is 'enabled' after the first boot"* ]]
}

@test "fence_verdict: a fence rule left in the ruleset fails and names keel's version (keel#322)" {
    run bt_fence_verdict disabled 1 0.23.105
    [ "$status" -eq 1 ]
    [[ $output == *"still holds the rule of the init fence (ct status dnat, keel#322)"* ]]
    [[ $output == *"keel 0.23.105 in the container"* ]]
}

@test "fence_verdict: a count that is not a number fails" {
    run bt_fence_verdict disabled "" 0.23.105
    [ "$status" -eq 1 ]
    [[ $output == *"cannot be read"* ]]
}

# the verdicts this appliance adds

STATUS_OK='{"installed":true,"maintenance":false,"needsDbUpgrade":false,"version":"32.0.1.2","versionstring":"32.0.1","edition":"","productname":"Nextcloud","extendedSupport":false}'
OCC_OK='{"installed":true,"version":"32.0.1.2","versionstring":"32.0.1","edition":"","maintenance":false,"needsDbUpgrade":false,"productname":"Nextcloud","extendedSupport":false}'

@test "usage: names the appliance and every proof" {
    run bt_usage
    [[ $output == *"(nextcloud)"* ]]
    [[ $output == *"status.php answers 200"* ]]
    [[ $output == *"keel-nextcloud-cron units"* ]]
}

@test "status_verdict: the wanted status passes, any other fails with both values" {
    run bt_status_verdict "/login" 200 200
    [ "$status" -eq 0 ]
    [ "$output" = "boot-test: /login answered 200" ]
    run bt_status_verdict "/config/config.php" 404 200
    [ "$status" -eq 1 ]
    [[ $output == *"/config/config.php answered 200, not 404"* ]]
    run bt_status_verdict "/login" 200
    [ "$status" -eq 1 ]
    [[ $output == *"answered , not 200"* ]]
}

@test "status_verdict: port 80 with a redirect is not port 80 with none" {
    run bt_status_verdict "http status.php" "200 " "200 "
    [ "$status" -eq 0 ]
    run bt_status_verdict "http status.php" "200 " "301 https://localhost/status.php"
    [ "$status" -eq 1 ]
}

@test "json_flag: true, false or empty, with or without spaces" {
    [ "$(bt_json_flag "$STATUS_OK" installed)" = true ]
    [ "$(bt_json_flag "$STATUS_OK" maintenance)" = false ]
    [ "$(bt_json_flag '{ "installed": true }' installed)" = true ]
    [ -z "$(bt_json_flag "$STATUS_OK" absent)" ]
    [ -z "$(bt_json_flag "" installed)" ]
}

@test "json_string: the value of a key, empty when absent" {
    [ "$(bt_json_string "$STATUS_OK" versionstring)" = 32.0.1 ]
    [ "$(bt_json_string '{"versionstring": "31.0.9"}' versionstring)" = 31.0.9 ]
    [ -z "$(bt_json_string "$STATUS_OK" absent)" ]
}

@test "nextcloud_state_verdict: status.php and occ status of a ready site pass" {
    run bt_nextcloud_state_verdict "status.php" "$STATUS_OK"
    [ "$status" -eq 0 ]
    [[ $output == *"status.php says installed, not in maintenance, database current, version 32.0.1"* ]]
    run bt_nextcloud_state_verdict "occ status" "$OCC_OK"
    [ "$status" -eq 0 ]
}

@test "nextcloud_state_verdict: not installed, in maintenance or an upgrade waiting fail" {
    run bt_nextcloud_state_verdict "status.php" '{"installed":false,"maintenance":false,"needsDbUpgrade":false}'
    [ "$status" -eq 1 ]
    [[ $output == *"does not say installed (installed: false)"* ]]
    run bt_nextcloud_state_verdict "status.php" '{"installed":true,"maintenance":true,"needsDbUpgrade":false}'
    [ "$status" -eq 1 ]
    [[ $output == *"out of maintenance (maintenance: true)"* ]]
    run bt_nextcloud_state_verdict "status.php" '{"installed":true,"maintenance":false,"needsDbUpgrade":true}'
    [ "$status" -eq 1 ]
    [[ $output == *"database is current (needsDbUpgrade: true)"* ]]
}

@test "nextcloud_state_verdict: a page that is not the JSON of status.php fails" {
    run bt_nextcloud_state_verdict "status.php" '<html><title>Access through untrusted domain</title></html>'
    [ "$status" -eq 1 ]
    [[ $output == *"(installed: absent)"* ]]
    run bt_nextcloud_state_verdict "status.php" '{"installed":true}'
    [ "$status" -eq 1 ]
    [[ $output == *"(maintenance: absent)"* ]]
    run bt_nextcloud_state_verdict "status.php"
    [ "$status" -eq 1 ]
}

@test "db_report_verdict: the account and both counts of 1 pass" {
    run bt_db_report_verdict "the web user" $'www-data@localhost\t1\t1' www-data nextcloud oc_users
    [ "$status" -eq 0 ]
    [[ $output == *"logs in as www-data@localhost and sees the nextcloud database and its oc_users table"* ]]
    run bt_db_report_verdict "lnmp" $'admin@%\t1\t1' admin nextcloud oc_users
    [ "$status" -eq 0 ]
}

@test "db_report_verdict: another account, no schema or no table fail" {
    run bt_db_report_verdict "the web user" $'root@localhost\t1\t1' www-data nextcloud oc_users
    [ "$status" -eq 1 ]
    [[ $output == *"not in the state the first boot should have left"* ]]
    run bt_db_report_verdict "the web user" $'www-data@localhost\t0\t0' www-data nextcloud oc_users
    [ "$status" -eq 1 ]
    run bt_db_report_verdict "the web user" $'www-data@localhost\t1\t0' www-data nextcloud oc_users
    [ "$status" -eq 1 ]
    run bt_db_report_verdict "the web user" "" www-data nextcloud oc_users
    [ "$status" -eq 1 ]
}

@test "redis_verdict: INFO answered and the Redis class for the locks pass" {
    info=$'# Server\r\nredis_version:8.0.2\r\nredis_mode:standalone\r\n'
    run bt_redis_verdict "$info" '\OC\Memcache\Redis'
    [ "$status" -eq 0 ]
    [[ $output == *"Redis 8.0.2 answers on its socket"* ]]
}

@test "redis_verdict: no INFO, or another class for the locks, fail" {
    run bt_redis_verdict "Could not connect to Redis at /run/redis/redis-server.sock" '\OC\Memcache\Redis'
    [ "$status" -eq 1 ]
    [[ $output == *"did not answer INFO"* ]]
    run bt_redis_verdict $'redis_version:8.0.2' '\OC\Memcache\APCu'
    [ "$status" -eq 1 ]
    [[ $output == *"names '\\OC\\Memcache\\APCu' for its file locks"* ]]
    run bt_redis_verdict $'redis_version:8.0.2' ""
    [ "$status" -eq 1 ]
}

@test "cron_verdict: mode cron, the timer enabled, the service loaded and not failed pass" {
    run bt_cron_verdict cron enabled loaded inactive
    [ "$status" -eq 0 ]
    [[ $output == *"keel-nextcloud-cron.service loaded (inactive)"* ]]
    run bt_cron_verdict cron enabled loaded active
    [ "$status" -eq 0 ]
}

@test "cron_verdict: each wrong field fails with its own message" {
    run bt_cron_verdict ajax enabled loaded inactive
    [ "$status" -eq 1 ]
    [[ $output == *"mode is 'ajax', not cron"* ]]
    run bt_cron_verdict cron disabled loaded inactive
    [ "$status" -eq 1 ]
    [[ $output == *"keel-nextcloud-cron.timer is 'disabled', not enabled"* ]]
    run bt_cron_verdict cron enabled not-found inactive
    [ "$status" -eq 1 ]
    [[ $output == *"keel-nextcloud-cron.service is 'not-found', not loaded"* ]]
    run bt_cron_verdict cron enabled loaded failed
    [ "$status" -eq 1 ]
    [[ $output == *"keel-nextcloud-cron.service is failed"* ]]
}

@test "instance.yaml: the values the verdicts read are the ones the spec declares" {
    spec="$BATS_TEST_DIRNAME/instance.yaml"
    grep -q "^    db_user: $BT_LNMP_DB_USER$" "$spec"
    grep -q "^    admin_user: $BT_NC_ADMIN_USER$" "$spec"
    grep -q "^    db_name: $BT_NC_DB_NAME$" "$spec"
    grep -q '^  name: nextcloud$' "$spec"
    for name in $BT_SECRETS; do
        grep -q "file: /etc/keel/secrets/$name$" "$spec"
    done
}

@test "boot-test.sh: executable, and --help prints the usage with exit 0" {
    [ -x "$BATS_TEST_DIRNAME/boot-test.sh" ]
    run "$BATS_TEST_DIRNAME/boot-test.sh" --help
    [ "$status" -eq 0 ]
    [[ ${lines[0]} == "usage: tests/boot-test.sh APPLIANCE"* ]]
    run "$BATS_TEST_DIRNAME/boot-test.sh" --verbose
    [ "$status" -eq 1 ]
}
