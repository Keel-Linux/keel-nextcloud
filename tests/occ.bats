#!/usr/bin/env bats
# Unit tests of overlay/usr/local/bin/keel-occ, with runuser as a stub

bats_require_minimum_version 1.5.0

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STUBS="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUBS"
    printf '#!/bin/bash\necho "runuser $* in $PWD"\n' > "$STUBS/runuser"
    chmod +x "$STUBS/runuser"
    export PATH="$STUBS:$PATH"
}

@test "keel-occ runs occ as the web user, from /" {
    run "$REPO/overlay/usr/local/bin/keel-occ" status --output=json
    [ "$status" -eq 0 ]
    [ "$output" = "runuser -u www-data -- php /var/www/nextcloud/occ status --output=json in /" ]
}
