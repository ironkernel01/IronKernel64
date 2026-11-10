#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 IronKernel
#
# ik64_host_tests.sh -- builds and runs the firmware host tests (tools/*_host_test.c) with the
#   MSYS2 UCRT64 GCC, the Python bank tests, then sid_host_test on the public tunes. Every test
#   prints its own PASS/FAIL line; this script prints "IK64_HOST_TESTS: <n> passed, <m> failed"
#   and exits 0 only when all passed.
# Usage (from any shell): scripts/ik64_host_tests.sh
# Needs: MSYS2 with mingw-w64-ucrt-x86_64-gcc at C:\msys64 (or gcc already on PATH), Python 3.
# Output: build/host_tests/<test>.exe and <test>.log.
# Revision: 11-10-2026 first version (the commands of chapter 11 of the specification).
R="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v gcc >/dev/null 2>&1; then
    [ -x /c/msys64/usr/bin/bash ] || { echo "ik64_host_tests: no gcc on PATH and no C:/msys64"; exit 2; }
    exec env MSYSTEM=UCRT64 /c/msys64/usr/bin/bash -lc "'$R/scripts/ik64_host_tests.sh'"
fi
cd "$R" || exit 2
mkdir -p build/host_tests
W="-std=c11 -Wall -Wextra -Werror"
pass=0; fail=0; targs=

t() {   # t <name> <gcc arguments...>; $targs are the test program's own arguments
    name="$1"; shift
    if gcc "$@" -o "build/host_tests/$name.exe" > "build/host_tests/$name.log" 2>&1 &&
       "./build/host_tests/$name.exe" $targs >> "build/host_tests/$name.log" 2>&1; then
        pass=$((pass + 1)); echo "PASS $name: $(tail -1 "build/host_tests/$name.log")"
    else
        fail=$((fail + 1)); echo "FAIL $name (build/host_tests/$name.log):"; tail -5 "build/host_tests/$name.log"
    fi
}

t bank_host_test $W -DIK64_BACKEND_RAM -DIK64_HOST_TEST -Ifw_1541/src -Icommon tools/bank_host_test.c \
    fw_1541/src/bank_format.c fw_1541/src/backend_ram.c fw_1541/src/cbmdos.c
t cbmdos_host_test $W -DIK64_BACKEND_RAM -Ifw_1541/src tools/cbmdos_host_test.c fw_1541/src/cbmdos.c
t c64screen_overlay_host_test $W -pedantic -Ifw_c64/src tools/c64screen_overlay_host_test.c fw_c64/src/c64screen.c
targs=fw_c64/cli/cli_commands.txt
t cli_menu_host_test $W -pedantic -Ifw_c64/cli tools/cli_menu_host_test.c fw_c64/cli/menu.c
targs=
t np_piano_host_test $W -pedantic -Ifw_c64/src tools/np_piano_host_test.c fw_c64/src/np_piano.c fw_c64/src/sid_envmodel.c
t np_switch_host_test $W -Ifw_c64/src -Icommon -Itools/host_stubs tools/np_switch_host_test.c \
    fw_c64/src/basic.c fw_c64/src/c64screen.c
t oled_host_test $W -DOLED_HOST_TEST -Ifw_c64/src -Icommon tools/oled_host_test.c fw_c64/src/oled.c \
    fw_c64/src/oled_ui.c fw_c64/src/font_openroms.c
t psid_cia_host_test $W -pedantic -Ifw_c64/src tools/psid_cia_host_test.c fw_c64/src/psid.c \
    fw_c64/src/c64mem.c fw_c64/src/cpu6502.c
t sid_envmodel_host_test $W -pedantic -Ifw_c64/src tools/sid_envmodel_host_test.c fw_c64/src/sid_envmodel.c

for py in public_bank_test bank_roundtrip_test; do
    if python -I "tools/$py.py" > "build/host_tests/$py.log" 2>&1; then
        pass=$((pass + 1)); echo "PASS $py: $(tail -1 "build/host_tests/$py.log")"
    else
        fail=$((fail + 1)); echo "FAIL $py (build/host_tests/$py.log):"; tail -5 "build/host_tests/$py.log"
    fi
done

# sid_host_test plays the public tunes that public_bank_test.py (tools/mkpublicbank.py) writes.
targs="$(ls build/bank/public/*.sid 2>/dev/null | tr '\n' ' ')"
if [ -n "$targs" ]; then
    t sid_host_test -O2 $W -pedantic -Ifw_c64/src tools/sid_host_test.c fw_c64/src/psid.c fw_c64/src/c64mem.c \
        fw_c64/src/cpu6502.c fw_c64/src/sid.c fw_c64/src/sid_tables.c
else
    fail=$((fail + 1)); echo "FAIL sid_host_test: no build/bank/public/*.sid (run python -I tools/mkpublicbank.py)"
fi
targs=

echo "IK64_HOST_TESTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
