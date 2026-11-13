#!/usr/bin/env bats
# The nginx routes of the overlay. In the cloud modes the front of keel-web
# (keel-front.d) answers first, with Coraza: the Core Rule Set answered 403
# for /config/config.php (rule 930130) and /data/nextcloud.log (rule
# 920440), where the route of the site answers 404 on a single node
# (commissioning, 2026-11-12). The front answers the forbidden paths of the
# site itself, with the same 404, so every mode gives one answer. The paths
# that start with a dot stay with the site: Anubis serves its challenge
# under /.within.website/ on the front.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SITE="$REPO/overlay/etc/nginx/keel-default.d/60-keel-nextcloud.conf"
    FRONT="$REPO/overlay/etc/nginx/keel-front.d/60-keel-nextcloud.conf"
}

# _denied FILE: the locations of FILE that answer 404 and nothing else
_denied() {
    grep -E '^location .*\{ return 404; \}$' "$1"
}

@test "the route of the site has forbidden paths" {
    run _denied "$SITE"
    [ "$status" -eq 0 ]
    [[ "$output" == *'config|lib'* ]]
    [[ "$output" == *'|data)'* ]]
}

@test "the front answers every forbidden path of the site with the same 404" {
    local line missing=()
    while IFS= read -r line; do
        grep -qxF -- "$line" "$FRONT" || missing+=("$line")
    done < <(_denied "$SITE" | grep -vF '^/(?:\.|')
    grep -qxF 'location ~ ^/(?:autotest|occ|issue|indie|db_|console) { return 404; }' "$FRONT" \
        || missing+=(autotest)
    if [[ ${#missing[@]} -gt 0 ]]; then
        printf 'not in the front: %s\n' "${missing[@]}"
        return 1
    fi
}

@test "the front denies no path that starts with a dot" {
    # "^/(?:\." or "^/\." would take /.within.website/ and /.well-known/
    [ -z "$(_denied "$FRONT" | grep -F -e '^/(?:\.' -e '^/\.')" ]
}

@test "the front denies the paths before it sends the sync paths on" {
    deny=$(grep -n 'return 404' "$FRONT" | head -1 | cut -d: -f1)
    sync=$(grep -n 'remote' "$FRONT" | grep location | head -1 | cut -d: -f1)
    [ -n "$deny" ] && [ -n "$sync" ]
    [ "$deny" -lt "$sync" ]
}
