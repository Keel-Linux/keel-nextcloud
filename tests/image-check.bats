#!/usr/bin/env bats
# Unit tests of bin/keel-nextcloud-image-check against a scratch tree
# (ROOT), with the owner of each path as stat reports it for the user who
# runs the tests.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    CHECK="$REPO/bin/keel-nextcloud-image-check"
    ROOT="$BATS_TEST_TMPDIR/root"
    me="$(id -un):$(id -gn)"
    mkdir -p "$ROOT/var/www/nextcloud/config" "$ROOT/var/www/nextcloud/custom_apps" \
        "$ROOT/var/lib/nextcloud/data" "$ROOT/var/log/nextcloud"
    : > "$ROOT/var/www/nextcloud/version.php"
    local file
    for file in /etc/nginx/keel-default.d/60-keel-nextcloud.conf \
            /etc/nginx/keel-front.d/60-keel-nextcloud.conf \
            /etc/nginx/keel-static.d/60-keel-nextcloud.conf \
            /etc/redis/redis.conf.d/20-keel-nextcloud.conf \
            /etc/systemd/system/keel-nextcloud-gate.timer \
            /etc/systemd/system/keel-nextcloud-cron.timer \
            /usr/lib/keel-nextcloud/keel-nextcloud-gate \
            /usr/lib/inithooks/firstboot.d/40nextcloud \
            /usr/share/keel/appliances/nextcloud.yaml; do
        mkdir -p "$ROOT$(dirname "$file")"
        : > "$ROOT$file"
    done
    echo 'include /etc/redis/redis.conf.d/*.conf' > "$ROOT/etc/redis/redis.conf"
    # stat answers root:root for version.php and the web user for the rest
    STUBS="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUBS"
    cat > "$STUBS/stat" <<SH
#!/bin/bash
case "\$3" in
    *version.php) echo "\${NC_TEST_CODE_OWNER:-root:root}" ;;
    *) /usr/bin/stat "\$@" ;;
esac
SH
    chmod +x "$STUBS/stat"
    export PATH="$STUBS:$PATH" ROOT WEB_OWNER="$me"
}

@test "a good tree passes" {
    run "$CHECK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "code that is not root's fails" {
    NC_TEST_CODE_OWNER=www-data:www-data run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not root's"* ]]
}

@test "a config.php, a pair file, CAN_INSTALL, an ACL, a pool or an open gate in the image fail" {
    : > "$ROOT/var/www/nextcloud/config/config.php"
    : > "$ROOT/var/www/nextcloud/config/keel-pair.config.php"
    : > "$ROOT/var/www/nextcloud/config/CAN_INSTALL"
    : > "$ROOT/etc/redis/redis.conf.d/50-keel-nextcloud-acl.conf"
    mkdir -p "$ROOT/etc/php/8.4/fpm/pool.d" "$ROOT/run/keel-nextcloud"
    : > "$ROOT/etc/php/8.4/fpm/pool.d/zz-keel-nextcloud.conf"
    : > "$ROOT/run/keel-nextcloud/open"
    run "$CHECK"
    [ "$status" -eq 6 ]
}

@test "a missing directory, file or include fails, one line each" {
    rmdir "$ROOT/var/log/nextcloud"
    rm "$ROOT/usr/share/keel/appliances/nextcloud.yaml" "$ROOT/var/www/nextcloud/version.php"
    : > "$ROOT/etc/redis/redis.conf"
    run "$CHECK"
    [ "$status" -eq 4 ]
    [[ "$output" == *"no Nextcloud code"* ]]
    [[ "$output" == *"no directory $ROOT/var/log/nextcloud"* ]]
    [[ "$output" == *"nextcloud.yaml is not in the image"* ]]
    [[ "$output" == *"does not include redis.conf.d"* ]]
}

@test "a directory of the wrong owner and the check page of lnmp fail" {
    WEB_OWNER=nobody:nogroup run "$CHECK"
    [ "$status" -eq 4 ]
    mkdir -p "$ROOT/usr/lib/inithooks/firstboot.d"
    : > "$ROOT/usr/lib/inithooks/firstboot.d/40lnmp-check"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"40lnmp-check of lnmp is still there"* ]]
}
