#!/usr/bin/env bats
# The modes of the files in the tree. fab runs only the conf scripts that
# are executable, and an overlay file keeps the mode of the checkout. The
# image 19.0-1 had no Nextcloud because conf.d/main was 0644 in git: fab
# did not run it, and said nothing (commissioning, 2026-11-12).

bats_require_minimum_version 1.5.0

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
}

# _executable DIR: fails with the names of the files in DIR that are not
# executable
_executable() {
    local file bad=()
    for file in "$REPO/$1"/*; do
        [[ -f "$file" ]] || continue
        [[ -x "$file" ]] || bad+=("${file#"$REPO"/}")
    done
    if [[ ${#bad[@]} -gt 0 ]]; then
        echo "not executable: ${bad[*]}"
        return 1
    fi
}

@test "every conf script is executable, so fab runs it" {
    _executable conf.d
}

@test "every first boot hook and inithooks program of the overlay is executable" {
    _executable overlay/usr/lib/inithooks/firstboot.d
    _executable overlay/usr/lib/inithooks/bin
}

@test "the gate, keel-occ and the image check are executable" {
    [ -x "$REPO/overlay/usr/lib/keel-nextcloud/keel-nextcloud-gate" ]
    [ -x "$REPO/overlay/usr/local/bin/keel-occ" ]
    [ -x "$REPO/bin/keel-nextcloud-image-check" ]
}
