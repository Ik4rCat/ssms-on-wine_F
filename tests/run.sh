#!/usr/bin/env bash
#
# tests/run.sh — smoke tests for ssms-patcher against synthetic fixtures.
#
# We generate two layouts:
#   flat   → mimics SSMS 20.0.x (Explorer.dll at the root of IDE/)
#   nested → mimics SSMS 20.2.x (Explorer.dll under Extensions/Application/)
# and run patch-gifs, restore, verify, locate against them.
#
# Requires: dotnet 10+ SDK (to build the tiny test assembly), coreutils.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PATCHER="${SSMS_PATCHER:-$ROOT/bin/ssms-patcher}"
[ -x "$PATCHER" ] || { echo "patcher not found or not executable: $PATCHER" >&2; exit 2; }

pass() { printf '\033[32m  ✔\033[0m %s\n' "$*"; }
fail() { printf '\033[31m  ✘\033[0m %s\n' "$*"; FAILURES=$((FAILURES+1)); }
FAILURES=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MSBuildEnableWorkloadResolver=false

# ---- build the tiny test DLL once ----
echo "[test] building Testasm.Explorer.dll ..."
( cd "$HERE/testasm" && dotnet build -c Release -o "$TMP/asm" >/dev/null )
ASM_DLL="$TMP/asm/Testasm.Explorer.dll"
[ -f "$ASM_DLL" ] || { echo "failed to build Testasm.Explorer.dll"; exit 2; }

# ---- helper: build a fixture layout ----
build_flat() {
    _root="$1"
    mkdir -p "$_root"
    # A fake Ssms.exe (any file — we don't rely on FileVersionInfo in tests).
    printf '\x4d\x5a' > "$_root/Ssms.exe"
    cp "$ASM_DLL" "$_root/Microsoft.SqlServer.Management.SqlStudio.Explorer.dll"
    # Nothing in Extensions/, nothing in Automation/.
}

build_nested() {
    _root="$1"
    mkdir -p "$_root/Extensions/Application" "$_root/Automation"
    printf '\x4d\x5a' > "$_root/Ssms.exe"
    cp "$ASM_DLL" "$_root/Extensions/Application/Microsoft.SqlServer.Management.SqlStudio.Explorer.dll"
    # Fake typelibs
    for n in dte80.olb dte80a.olb dte90.olb dte90a.olb dte100.olb; do
        printf 'olb' > "$_root/Automation/$n"
    done
    # A .pkgdef sibling so IsPackageAssembly() flips true for this DLL —
    # the patcher must SKIP it during patch-gifs by default.
    printf '[$RootKey$\\Packages\\{00000000-0000-0000-0000-000000000000}]\n' \
        > "$_root/Extensions/Application/Microsoft.SqlServer.Management.SqlStudio.Explorer.pkgdef"
}

# ---- test: locate handles both layouts ----
FLAT="$TMP/flat"
NEST="$TMP/nested"
build_flat "$FLAT"
build_nested "$NEST"

echo "[test] locate on flat layout"
if "$PATCHER" locate "$FLAT" | grep -F "Microsoft.SqlServer.Management.SqlStudio.Explorer.dll" >/dev/null; then
    pass "locate reports Explorer.dll at flat root"
else
    fail "locate did not find Explorer.dll in flat layout"
fi

echo "[test] locate on nested layout"
NEST_LOC="$("$PATCHER" locate "$NEST" || true)"
if printf '%s' "$NEST_LOC" | grep -F "Extensions/Application" >/dev/null; then
    pass "locate finds Explorer.dll under Extensions/Application"
else
    fail "locate missed Explorer.dll in Extensions/Application"
    printf '%s\n' "$NEST_LOC"
fi
if printf '%s' "$NEST_LOC" | grep -F "dte80a.olb" >/dev/null; then
    pass "locate finds typelibs under Automation/"
else
    fail "locate missed typelibs under Automation/"
fi

# ---- test: patch-gifs modifies the flat DLL, restore reverses it ----
echo "[test] patch-gifs on flat layout"
ORIG_HASH="$(sha256sum "$FLAT/Microsoft.SqlServer.Management.SqlStudio.Explorer.dll" | awk '{print $1}')"
"$PATCHER" patch-gifs "$FLAT" >"$TMP/gifs-flat.log" 2>&1 || true
if grep -F "GIFs replaced" "$TMP/gifs-flat.log" >/dev/null; then
    pass "patch-gifs reported replacement on flat"
else
    fail "patch-gifs did not report replacement on flat"
    sed -n '1,40p' "$TMP/gifs-flat.log"
fi
if [ -f "$FLAT/Microsoft.SqlServer.Management.SqlStudio.Explorer.dll.orig-gif" ]; then
    pass "backup .orig-gif created"
else
    fail "backup .orig-gif not created"
fi

# idempotency: running again does not create a second backup nor mutate more
echo "[test] patch-gifs idempotent"
"$PATCHER" patch-gifs "$FLAT" >"$TMP/gifs-flat-2.log" 2>&1 || true
BAK_COUNT=$(find "$FLAT" -name '*.orig-gif' | wc -l | tr -d ' ')
if [ "$BAK_COUNT" = "1" ]; then
    pass "single backup after re-run"
else
    fail "expected 1 backup, got $BAK_COUNT"
fi

# ---- test: restore reverts byte-for-byte ----
echo "[test] restore --file returns file byte-for-byte to original"
"$PATCHER" restore "$FLAT" --file \
    "$FLAT/Microsoft.SqlServer.Management.SqlStudio.Explorer.dll" >/dev/null
NEW_HASH="$(sha256sum "$FLAT/Microsoft.SqlServer.Management.SqlStudio.Explorer.dll" | awk '{print $1}')"
if [ "$ORIG_HASH" = "$NEW_HASH" ]; then
    pass "restore produced byte-identical file"
else
    fail "hash mismatch after restore: orig=$ORIG_HASH new=$NEW_HASH"
fi
if [ ! -f "$FLAT/Microsoft.SqlServer.Management.SqlStudio.Explorer.dll.orig-gif" ]; then
    pass "backup .orig-gif removed after restore"
else
    fail "backup .orig-gif still present after restore"
fi

# ---- test: patch-gifs skips DLLs with a .pkgdef sibling by default ----
echo "[test] patch-gifs skips VS-package assemblies on nested layout"
"$PATCHER" patch-gifs "$NEST" >"$TMP/gifs-nested.log" 2>&1 || true
if ! [ -f "$NEST/Extensions/Application/Microsoft.SqlServer.Management.SqlStudio.Explorer.dll.orig-gif" ]; then
    pass "package assembly was skipped (no .orig-gif backup)"
else
    fail "package assembly was NOT skipped — patcher wrote through"
fi
if grep -F "skip (VS package" "$TMP/gifs-nested.log" >/dev/null; then
    pass "skip reason logged"
else
    fail "skip reason not logged"
    sed -n '1,40p' "$TMP/gifs-nested.log"
fi

# ---- test: --force-strong overrides the package-assembly skip? ----
# (only a skip warning gate — force-strong is for strong-named checks;
# package skip is separate. Skipping this branch for now.)

# ---- test: verify prints backup counts ----
echo "[test] verify prints backup counts"
build_flat "$TMP/verify-fx"
"$PATCHER" patch-gifs "$TMP/verify-fx" >/dev/null 2>&1 || true
if "$PATCHER" verify "$TMP/verify-fx" | grep -F "GIF-patched DLLs:  1" >/dev/null; then
    pass "verify reports 1 GIF-patched DLL"
else
    fail "verify did not report GIF-patched DLL count correctly"
    "$PATCHER" verify "$TMP/verify-fx"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "all tests passed."
    exit 0
else
    echo "$FAILURES test(s) failed."
    exit 1
fi
