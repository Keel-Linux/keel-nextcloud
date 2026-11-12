#!/usr/bin/env bats
# bin/nextcloud.py draws its dialog on the terminal, not in the hook's pipe.
#
# firstboot.d/40nextcloud reads the script's standard output for KEY=value,
# and dialog draws its screen on standard output. On 2026-09-30 a
# keel-wordpress first boot on Proxmox froze at a password box (the same
# dialog), because the box
# was drawn into that pipe. These tests run the script as the hook does,
# output redirected, inside a real pseudo terminal (script(1)), with a
# stand-in for libinithooks whose dialog refuses to draw anywhere but a
# terminal.

setup() {
    here="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    NEXTCLOUD_PY="$here/../overlay/usr/lib/inithooks/bin/nextcloud.py"
    FAKE="$BATS_TEST_TMPDIR/lib"
    mkdir -p "$FAKE/libinithooks"
    : > "$FAKE/libinithooks/__init__.py"
    cat > "$FAKE/libinithooks/dialog_wrapper.py" << 'EOF'
import os


class Dialog:
    def __init__(self, title):
        self.title = title

    def get_password(self, title, text):
        # what dialog needs to be seen: a terminal on standard output
        if not os.isatty(1):
            raise SystemExit("dialog would draw into a pipe")
        return "typed-at-the-console"
EOF
    OUT="$BATS_TEST_TMPDIR/answers"
}

run_as_the_hook() {
    # stdin and /dev/tty are the pseudo terminal; stdout is a file, as the
    # hook's process substitution makes it a pipe
    script -qec "PYTHONPATH='$FAKE' python3 '$NEXTCLOUD_PY' $* > '$OUT'" /dev/null
}

@test "the answers reach the hook while the dialog draws on the terminal" {
    run run_as_the_hook APP_PASS
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "APP_PASS=typed-at-the-console" ]
}

@test "without any terminal it says so instead of a traceback" {
    # setsid: no controlling terminal, and standard input is not one either
    PYTHONPATH="$FAKE" run setsid -w python3 "$NEXTCLOUD_PY" APP_PASS < /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"no terminal to draw the dialog on"* ]]
    [[ "$output" == *"secrets.app_password"* ]]
    [[ "$output" != *"Traceback"* ]]
}

# Under `pct enter` the terminal is a pty of the Proxmox host (/dev/pts/3).
# The root of an unprivileged container cannot open it again by its path:
# "/dev/pts/3: Permission denied" (BR2, 2026-11-05). The process already
# holds that terminal on its descriptors, so the script duplicates one of
# them and opens a path only when it has none. Here every open by path is
# refused, as there.

# run_without_open REDIRECTIONS: answers_out() with os.open refused, in a
# pty, with the descriptors REDIRECTIONS gives; stdout is a file, as in the
# hook, and it receives the answer and whether stdout became the terminal
run_without_open() {
    cat > "$BATS_TEST_TMPDIR/no-open.py" << 'EOF2'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("nextcloud", sys.argv[1])
nextcloud = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nextcloud)


def refused(path, *args, **kwargs):
    raise PermissionError(13, "Permission denied", path)


os.open = refused
answers = nextcloud.answers_out()
print(f"answer, terminal on stdout: {os.isatty(1)}", file=answers)
answers.close()
EOF2
    script -qec "PYTHONPATH='$FAKE' python3 '$BATS_TEST_TMPDIR/no-open.py' '$NEXTCLOUD_PY' $1 > '$OUT'" /dev/null
}

@test "a terminal on standard input is duplicated, not opened again by its path" {
    # standard error is a file, so only standard input is a terminal
    run run_without_open "2> '$BATS_TEST_TMPDIR/stderr'"
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "answer, terminal on stdout: True" ]
}

@test "with no terminal on standard input, the one on standard error is duplicated" {
    run run_without_open "< /dev/null"
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "answer, terminal on stdout: True" ]
}

@test "a terminal open for reading only is not one to draw on" {
    # the shell opens /dev/tty for reading only with <: the dialog cannot
    # draw there, so standard error is the one duplicated
    run run_without_open "< /dev/tty"
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "answer, terminal on stdout: True" ]
    # and with standard error a file, there is no terminal to draw on
    run run_without_open "< /dev/tty 2> '$BATS_TEST_TMPDIR/stderr'"
    [ "$status" -ne 0 ]
    grep -q "no terminal to draw the dialog on" "$BATS_TEST_TMPDIR/stderr"
}

@test "with no terminal on a descriptor and none to open, it says so" {
    run run_without_open "< /dev/null 2> '$BATS_TEST_TMPDIR/stderr'"
    [ "$status" -ne 0 ]
    grep -q "no terminal to draw the dialog on" "$BATS_TEST_TMPDIR/stderr"
    run grep -c Traceback "$BATS_TEST_TMPDIR/stderr"
    [ "$output" = 0 ]
}

@test "the whole dialog runs under a pty it cannot open again by its path" {
    cat > "$BATS_TEST_TMPDIR/no-open-main.py" << 'EOF'
import os
import runpy
import sys


def refused(path, *args, **kwargs):
    raise PermissionError(13, "Permission denied", path)


os.open = refused
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
EOF
    run script -qec "PYTHONPATH='$FAKE' python3 '$BATS_TEST_TMPDIR/no-open-main.py' '$NEXTCLOUD_PY' APP_PASS > '$OUT'" /dev/null
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "APP_PASS=typed-at-the-console" ]
}

@test "without a name it prints its usage and fails" {
    PYTHONPATH="$FAKE" run python3 "$NEXTCLOUD_PY"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Syntax: nextcloud.py NAME"* ]]
}
