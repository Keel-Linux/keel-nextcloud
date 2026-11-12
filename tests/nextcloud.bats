#!/usr/bin/env bats
# Unit tests of overlay/usr/lib/inithooks/lib/nextcloud.sh, the logic of the
# first boot hook and of the gate. No root, database, Redis or network.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    # shellcheck source=../overlay/usr/lib/inithooks/lib/nextcloud.sh
    source "$REPO/overlay/usr/lib/inithooks/lib/nextcloud.sh"
    SCRATCH="$BATS_TEST_TMPDIR"
}

@test "first_value skips empty values and the DEFAULT placeholder" {
    run nextcloud_first_value "" default "DEFAULT" chosen other
    [ "$status" -eq 0 ]
    [ "$output" = chosen ]
}

@test "first_value fails when nothing is set" {
    run nextcloud_first_value "" DEFAULT
    [ "$status" -eq 1 ]
}

@test "admin_user is the default admin when nothing is declared" {
    run nextcloud_admin_user ""
    [ "$output" = admin ]
}

@test "admin_user takes a declared login and refuses one with a space" {
    run nextcloud_admin_user "ops.team@example"
    [ "$output" = ops.team@example ]
    run nextcloud_admin_user "bad name"
    [ "$status" -eq 1 ]
}

@test "db_name takes an identifier and refuses a name that needs quoting" {
    run nextcloud_db_name ""
    [ "$output" = nextcloud ]
    run nextcloud_db_name "nc_main"
    [ "$output" = nc_main ]
    run nextcloud_db_name 'nc`; DROP'
    [ "$status" -eq 1 ]
}

@test "domain is the host name of a URL, in lower case" {
    run nextcloud_domain "https://Cloud.Example.org/index.php"
    [ "$output" = cloud.example.org ]
    run nextcloud_domain "http://files.example.org"
    [ "$output" = files.example.org ]
}

@test "domain falls back to localhost and refuses a value that is not a host name" {
    run nextcloud_domain ""
    [ "$output" = localhost ]
    run nextcloud_domain "bad_host!"
    [ "$status" -eq 1 ]
}

@test "spec_role is empty with no spec file" {
    run nextcloud_spec_role "$SCRATCH/none.yaml"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "spec_role reads database.server.role" {
    printf 'database:\n  server:\n    role: replica\n' > "$SCRATCH/spec.yaml"
    run nextcloud_spec_role "$SCRATCH/spec.yaml"
    [ "$output" = replica ]
}

@test "spec_role is empty when the spec declares no role" {
    printf 'app:\n  domain: x\n' > "$SCRATCH/spec.yaml"
    run nextcloud_spec_role "$SCRATCH/spec.yaml"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "spec_role fails on a spec whose database is not a mapping" {
    printf 'database: [1, 2]\n' > "$SCRATCH/spec.yaml"
    run nextcloud_spec_role "$SCRATCH/spec.yaml"
    [ "$status" -ne 0 ]
}

@test "is_replica: the declared role or a read-only server" {
    nextcloud_is_replica replica 0
    nextcloud_is_replica primary 1
    nextcloud_is_replica "" ON
    run nextcloud_is_replica primary 0
    [ "$status" -eq 1 ]
    run nextcloud_is_replica "" OFF
    [ "$status" -eq 1 ]
}

@test "missing_values names each value that is not there" {
    run nextcloud_missing_values primary "" "" "" "" ""
    [ "${lines[0]}" = app_password ]
    [ "${lines[1]}" = nextcloud_secret ]
    [ "${lines[2]}" = nextcloud_passwordsalt ]
    [ "${lines[3]}" = redis_password ]
    [ "${lines[4]}" = redis_session_password ]
}

@test "missing_values: a replica needs no administrator password" {
    run nextcloud_missing_values replica "" s p r q
    [ -z "$output" ]
    run nextcloud_missing_values primary pass s p r q
    [ -z "$output" ]
}

@test "instance_id is the same for the same secret and differs for another" {
    a=$(nextcloud_instance_id "secret-one")
    b=$(nextcloud_instance_id "secret-one")
    c=$(nextcloud_instance_id "secret-two")
    [ "$a" = "$b" ]
    [ "$a" != "$c" ]
    [[ $a =~ ^oc[0-9a-f]{10}$ ]]
}

@test "instance_id fails with no secret" {
    run nextcloud_instance_id ""
    [ "$status" -eq 1 ]
}

@test "php_quote escapes a backslash and a single quote" {
    run nextcloud_php_quote "a'b\\c"
    [ "$output" = "'a\\'b\\\\c'" ]
}

@test "pair_config_php is valid PHP and holds the values" {
    nextcloud_pair_config_php "the'secret" "salt" "redis-pass" > "$SCRATCH/pair.php"
    if command -v php > /dev/null; then
        run php -r '$CONFIG = []; include $argv[1]; echo $CONFIG["secret"], "|", $CONFIG["passwordsalt"], "|", $CONFIG["redis"]["password"], "|", $CONFIG["memcache.locking"], "|", $CONFIG["instanceid"];' "$SCRATCH/pair.php"
        [ "$status" -eq 0 ]
        [ "$output" = "the'secret|salt|redis-pass|\\OC\\Memcache\\Redis|$(nextcloud_instance_id "the'secret")" ]
    else
        grep -q "'secret' => 'the\\\\'secret'" "$SCRATCH/pair.php"
    fi
}

@test "pair_config_php fails when a value is missing" {
    run nextcloud_pair_config_php "secret" "" "redis"
    [ "$status" -eq 1 ]
}

@test "pair_config_php fails when the instance id cannot be made" {
    sha256sum() { return 1; }
    run nextcloud_pair_config_php "secret" "salt" "redis"
    [ "$status" -eq 1 ]
}

@test "node_config_json lists the domain and the addresses, IPv6 in brackets" {
    run nextcloud_node_config_json cloud.example.org 2804:db8::1 "" 10.0.0.5
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
c = json.load(sys.stdin)["system"]
assert c["trusted_domains"] == ["localhost", "cloud.example.org", "[2804:db8::1]", "10.0.0.5"], c
assert c["overwrite.cli.url"] == "https://cloud.example.org"
assert c["logfile"] == "/var/log/nextcloud/nextcloud.log"
assert c["apps_paths"][1]["writable"] is True
'
}

@test "node_config_json carries no secret" {
    run nextcloud_node_config_json cloud.example.org
    [[ "$output" != *secret* ]]
    [[ "$output" != *password* ]]
}

@test "node_config_json fails with no domain" {
    run nextcloud_node_config_json ""
    [ "$status" -eq 1 ]
}

@test "node_config_php lists the same settings as PHP entries" {
    run nextcloud_node_config_php cloud.example.org 2804:db8::1 "" 10.0.0.5
    [ "$status" -eq 0 ]
    [[ "$output" == *"'trusted_domains' => ['localhost', 'cloud.example.org', '[2804:db8::1]', '10.0.0.5'],"* ]]
    [[ "$output" == *"'datadirectory' => '/var/lib/nextcloud/data',"* ]]
    [[ "$output" == *"'loglevel' => 3,"* ]]
    [[ "$output" == *"'writable' => true"* ]]
}

@test "node_config_php fails with no domain" {
    run nextcloud_node_config_php ""
    [ "$status" -eq 1 ]
}

@test "redis_digest is the SHA-256 of the password" {
    run nextcloud_redis_digest "pass"
    [ "$output" = "$(printf %s pass | sha256sum | cut -d' ' -f1)" ]
    run nextcloud_redis_digest ""
    [ "$status" -eq 1 ]
}

@test "redis_digest fails when sha256sum fails" {
    sha256sum() { return 1; }
    run nextcloud_redis_digest "pass"
    [ "$status" -eq 1 ]
}

@test "redis_acl holds digests, never the passwords, and limits the session user" {
    run nextcloud_redis_acl "main-pass" "session-pass"
    [ "$status" -eq 0 ]
    [[ "$output" != *main-pass* ]]
    [[ "$output" != *session-pass* ]]
    [[ "$output" == *"user default on nopass -@all +info"* ]]
    [[ "$output" == *"user nextcloud on #$(nextcloud_redis_digest main-pass) ~* &* +@all"* ]]
    [[ "$output" == *"user nextcloud-session on #$(nextcloud_redis_digest session-pass) resetkeys ~PHPREDIS_SESSION:* resetchannels -@all"* ]]
    [[ "$output" != *flushall* ]]
}

@test "redis_acl fails without either password" {
    run nextcloud_redis_acl "" "s"
    [ "$status" -eq 1 ]
    run nextcloud_redis_acl "m" ""
    [ "$status" -eq 1 ]
}

@test "session_pool uses the session user, not the main one" {
    run nextcloud_session_pool "session-pass"
    [[ "$output" == *"auth[user]=nextcloud-session&auth[pass]=session-pass"* ]]
    [[ "$output" == *"session.save_handler] = redis"* ]]
    run nextcloud_session_pool ""
    [ "$status" -eq 1 ]
}

@test "gate is open only on a ready node whose database takes writes" {
    [ "$(nextcloud_gate yes '' 0)" = open ]
    [ "$(nextcloud_gate yes 'role=primary' OFF)" = open ]
    [ "$(nextcloud_gate no '' 0)" = closed ]
    [ "$(nextcloud_gate yes '' 1)" = closed ]
    [ "$(nextcloud_gate yes '' unknown)" = closed ]
    [ "$(nextcloud_gate yes 'role=replica' 0)" = closed ]
}

@test "gate_action flushes Redis when the node becomes the writer" {
    [ "$(nextcloud_gate_action closed open)" = flush-open ]
    [ "$(nextcloud_gate_action open closed)" = close ]
    [ "$(nextcloud_gate_action open open)" = none ]
    [ "$(nextcloud_gate_action closed closed)" = none ]
}

@test "code_version reads OC_Version of version.php" {
    printf '<?php\n$OC_Version = array(35,0,2,2);\n$OC_VersionString = '"'"'35.0.2'"'"';\n' > "$SCRATCH/version.php"
    run nextcloud_code_version "$SCRATCH/version.php"
    [ "$output" = 35.0.2.2 ]
}

@test "code_version fails on a missing file or a file without a version" {
    run nextcloud_code_version "$SCRATCH/none.php"
    [ "$status" -eq 1 ]
    printf '<?php\n' > "$SCRATCH/version.php"
    run nextcloud_code_version "$SCRATCH/version.php"
    [ "$status" -eq 1 ]
    printf '<?php\n$OC_Version = array();\n' > "$SCRATCH/version.php"
    run nextcloud_code_version "$SCRATCH/version.php"
    [ "$status" -eq 1 ]
}

@test "newest_core_migration is the newest Version file" {
    mkdir "$SCRATCH/m"
    touch "$SCRATCH/m/Version34000Date20260521110333.php" "$SCRATCH/m/Version35000Date20260527162338.php" "$SCRATCH/m/README"
    run nextcloud_newest_core_migration "$SCRATCH/m"
    [ "$output" = 35000Date20260527162338 ]
}

@test "newest_core_migration fails with no directory or no migration" {
    run nextcloud_newest_core_migration "$SCRATCH/none"
    [ "$status" -eq 1 ]
    mkdir "$SCRATCH/empty"
    run nextcloud_newest_core_migration "$SCRATCH/empty"
    [ "$status" -eq 1 ]
}

@test "follow_action sets the version only when the database is at the code" {
    [ "$(nextcloud_follow_action 35.0.2.2 35.0.2.2 1)" = none ]
    [ "$(nextcloud_follow_action 35.0.2.2 34.0.5.1 1)" = set ]
    [ "$(nextcloud_follow_action 35.0.2.2 34.0.5.1 0)" = wait ]
    [ "$(nextcloud_follow_action 35.0.2.2 34.0.5.1 '')" = wait ]
    run nextcloud_follow_action "" 34 1
    [ "$status" -eq 1 ]
}

@test "wait_ready returns at the first success and fails after the tries" {
    NEXTCLOUD_WAIT_SLEEP=0
    run nextcloud_wait_ready true 3
    [ "$status" -eq 0 ]
    run nextcloud_wait_ready false 2
    [ "$status" -eq 1 ]
}

@test "masked shows the length only" {
    run nextcloud_masked "abcdef"
    [ "$output" = "(6 characters)" ]
}
