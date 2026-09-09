#!/usr/bin/env bash
#
# setup-ssms.sh — install SQL Server Management Studio 20 under Wine on
#                 Linux (Ubuntu / Arch) and macOS.
#
# Usage:
#   ./setup-ssms.sh [/path/to/SSMS-Setup-ENU.exe] [WINEPREFIX]
#   ./setup-ssms.sh doctor      [WINEPREFIX]
#   ./setup-ssms.sh reset-cache [WINEPREFIX]
#   ./setup-ssms.sh --only <stage> [/path/to/SSMS-Setup-ENU.exe] [WINEPREFIX]
#   ./setup-ssms.sh --resume       [/path/to/SSMS-Setup-ENU.exe] [WINEPREFIX]
#   ./setup-ssms.sh --help
#
# When the installer path is omitted the script prints the Microsoft
# download URL and opens it in the default browser (xdg-open / open).
# It does NOT download SSMS itself — Microsoft's EULA doesn't allow
# redistribution.
#
# Stages (used by --only / --resume, executed in this order):
#   deps redirects_early prefix installer copy_dlls redirects
#   patch_gifs patch_nav reset_cache launcher
#
# We intentionally do NOT run `set -e` around patch stages: a failed
# patch is logged and reported at the end, but never aborts the run —
# the launcher and DLL copies still land.

set -u

# macOS ships bash 3.2; keep the script 3.2-safe (no `${x,,}`,
# no `declare -A`, no `local -a`, no `mapfile`, no `readarray`).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER_URL="https://go.microsoft.com/fwlink/?linkid=2313753&clcid=0x409"
RELEASE_REPO="${SSMS_RELEASE_REPO:-Ik4rCat/ssms-on-wine_F}"
FALLBACK_REPO="WilhelmZA/ssms-on-wine"

log()  { printf '\033[1;34m[ssms-setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ssms-setup]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ssms-setup]\033[0m %s\n' "$*" >&2; }
die()  { err "FATAL: $*"; exit 1; }
ask()  {
    # No-tty: assume yes. macOS bash 3.2 supports `read -r -p`.
    [ -t 0 ] || return 0
    printf '%s [Y/n] ' "$1"
    read -r a
    case "$a" in [Nn]*) return 1 ;; *) return 0 ;; esac
}

# -----------------------------------------------------------------
# argument parsing
# -----------------------------------------------------------------
MODE="install"          # install | doctor | reset-cache
ONLY_STAGE=""
RESUME=0
INSTALLER=""
WINEPREFIX_ARG="$HOME/.wine-ssms"

positional=""
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            sed -n '3,20p' "$0"; exit 0 ;;
        --only)
            [ -n "${2:-}" ] || die "--only requires a stage name"
            ONLY_STAGE="$2"; shift 2 ;;
        --resume)
            RESUME=1; shift ;;
        doctor|reset-cache)
            MODE="$1"; shift ;;
        --) shift; break ;;
        -*) die "unknown flag: $1" ;;
        *)
            if [ -z "$positional" ]; then positional="$1"
            else positional="$positional::$1"; fi
            shift ;;
    esac
done

# Split :: pairs — bash 3.2 friendly (no arrays in `local`).
POS1="${positional%%::*}"
POS2=""
case "$positional" in *::*) POS2="${positional#*::}" ;; esac

case "$MODE" in
    install)
        INSTALLER="$POS1"
        [ -n "$POS2" ] && WINEPREFIX_ARG="$POS2" ;;
    doctor|reset-cache)
        [ -n "$POS1" ] && WINEPREFIX_ARG="$POS1" ;;
esac

export WINEPREFIX="$WINEPREFIX_ARG"
export WINEARCH="${WINEARCH:-win64}"

# -----------------------------------------------------------------
# platform detection
# -----------------------------------------------------------------
UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"
case "$UNAME_S" in
    Linux)
        if command -v pacman >/dev/null 2>&1; then PLATFORM=arch
        elif command -v apt-get >/dev/null 2>&1; then PLATFORM=debian
        else PLATFORM=linux-other; fi ;;
    Darwin) PLATFORM=macos ;;
    *) die "unsupported OS: $UNAME_S" ;;
esac

case "$PLATFORM-$UNAME_M" in
    macos-arm64)      PATCHER_RID=osx-arm64 ;;
    macos-x86_64)     PATCHER_RID=osx-x64 ;;
    *-x86_64|*-amd64) PATCHER_RID=linux-x64 ;;
    *) die "unsupported architecture: $UNAME_M" ;;
esac
log "platform: $PLATFORM $UNAME_M (patcher RID: $PATCHER_RID)"

# -----------------------------------------------------------------
# openers, downloaders
# -----------------------------------------------------------------
open_url() {
    _u="$1"
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$_u" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then
        open "$_u" >/dev/null 2>&1 &
    elif command -v start >/dev/null 2>&1; then
        start "$_u" >/dev/null 2>&1 &
    else
        warn "cannot open the URL automatically — copy it manually."
        return 1
    fi
    return 0
}

download_patcher() {
    _dest="$1"; _rid="$2"
    mkdir -p "$(dirname "$_dest")"
    for _repo in "$RELEASE_REPO" "$FALLBACK_REPO"; do
        _url="https://github.com/$_repo/releases/latest/download/ssms-patcher-$_rid"
        log "trying: $_url"
        if curl -sSL -f -o "$_dest" "$_url"; then
            chmod +x "$_dest"; return 0
        fi
    done
    return 1
}

build_patcher() {
    _dest="$1"; _rid="$2"
    command -v dotnet >/dev/null 2>&1 || die "dotnet SDK not installed — cannot build patcher for $_rid"
    log "building patcher for $_rid from source (2-3 minutes)..."
    ( cd "$SCRIPT_DIR/src" && \
      MSBuildEnableWorkloadResolver=false \
      dotnet publish -c Release -r "$_rid" --self-contained -o "$SCRIPT_DIR/bin-$_rid" >/dev/null ) \
        || return 1
    cp "$SCRIPT_DIR/bin-$_rid/ssms-patcher" "$_dest" || return 1
    chmod +x "$_dest"
    return 0
}

# -----------------------------------------------------------------
# early usage: prompt for the installer if the user didn't supply one
# -----------------------------------------------------------------
prompt_download() {
    cat <<EOF
${INSTALLER_URL}

SSMS 20.2.1 is a Microsoft product — this script cannot redistribute
the installer. Download it once and re-run this script with:

    ./setup-ssms.sh /path/to/SSMS-Setup-ENU.exe

EOF
    if ask "Open the download page in your browser now?"; then
        open_url "$INSTALLER_URL" || true
    fi
}

# -----------------------------------------------------------------
# doctor
# -----------------------------------------------------------------
run_doctor() {
    log "running diagnostics against WINEPREFIX=$WINEPREFIX"
    printf '\n'
    _ok=0; _bad=0
    check() {
        # $1: label, $2: shell test, $3: hint on failure
        if eval "$2" >/dev/null 2>&1; then
            printf '  \033[32m✔\033[0m %s\n' "$1"; _ok=$((_ok+1))
        else
            printf '  \033[31m✘\033[0m %s\n' "$1"
            [ -n "${3:-}" ] && printf '      hint: %s\n' "$3"
            _bad=$((_bad+1))
        fi
    }

    check "wine on PATH" "command -v wine" "install wine-stable 11.x (winehq or distro)"
    if command -v wine >/dev/null 2>&1; then
        _wv="$(wine --version 2>/dev/null || true)"
        printf '        wine: %s\n' "$_wv"
        case "$_wv" in
            wine-1[1-9].*|wine-[2-9][0-9].*) : ;;
            *) printf '        \033[33m! upstream tested only on wine-11.x\033[0m\n' ;;
        esac
    fi
    check "winetricks on PATH" "command -v winetricks"
    check "curl on PATH" "command -v curl"
    check "unzip on PATH" "command -v unzip"
    check "python3 on PATH" "command -v python3"

    case "$PLATFORM" in
        arch)
            check "[multilib] enabled in /etc/pacman.conf" \
                  "grep -qE '^[[:space:]]*\[multilib\]' /etc/pacman.conf" \
                  "uncomment [multilib] and Include line, then: sudo pacman -Syu" ;;
        debian)
            check "dpkg foreign i386 arch" "dpkg --print-foreign-architectures | grep -qx i386" \
                  "sudo dpkg --add-architecture i386 && sudo apt update" ;;
    esac

    if [ "$PLATFORM" != "macos" ]; then
        check "32-bit unixODBC (libodbc.so.2)" \
              "ldconfig -p 2>/dev/null | grep -Fq 'libodbc.so.2' && ldconfig -p 2>/dev/null | grep -F 'libodbc.so.2' | grep -qE 'i386|libc6,x32|32-bit'" \
              "Arch: sudo pacman -S lib32-unixodbc; Debian: sudo apt install libodbc1:i386"
    fi

    check "wine prefix directory exists" "[ -d '$WINEPREFIX' ]" \
          "run this script without --doctor to create it"
    _ide="$WINEPREFIX/drive_c/Program Files (x86)/Microsoft SQL Server Management Studio 20/Common7/IDE"
    check "SSMS IDE dir present" "[ -d \"$_ide\" ]" \
          "run the installer stage: ./setup-ssms.sh /path/to/SSMS-Setup-ENU.exe"
    if [ -f "$_ide/Ssms.exe" ]; then
        printf '        Ssms.exe: %s\n' "$_ide/Ssms.exe"
    fi

    # Free space check (~15 GB during install)
    _free_kb=0
    if command -v df >/dev/null 2>&1; then
        _free_kb="$(df -Pk "$(dirname "$WINEPREFIX")" 2>/dev/null | awk 'NR==2{print $4}')"
    fi
    if [ -n "$_free_kb" ] && [ "$_free_kb" -gt $((15*1024*1024)) ]; then
        printf '  \033[32m✔\033[0m free disk on prefix filesystem: %s GB\n' "$((_free_kb/1024/1024))"
        _ok=$((_ok+1))
    else
        printf '  \033[31m✘\033[0m free disk on prefix filesystem: %s GB (need ~15)\n' \
            "$((_free_kb/1024/1024))"
        _bad=$((_bad+1))
    fi

    # Patcher present and functional
    _patcher="$SCRIPT_DIR/bin/ssms-patcher"
    if [ -x "$_patcher" ] && "$_patcher" --help >/dev/null 2>&1; then
        printf '  \033[32m✔\033[0m ssms-patcher runnable: %s\n' "$_patcher"
        _ok=$((_ok+1))
        if [ -d "$_ide" ]; then
            printf '  ---- ssms-patcher locate ----\n'
            "$_patcher" locate "$_ide" || true
            printf '  ---- ssms-patcher verify ----\n'
            "$_patcher" verify "$_ide" || true
        fi
    else
        printf '  \033[31m✘\033[0m ssms-patcher missing or not runnable\n'
        _bad=$((_bad+1))
    fi

    # NVIDIA hint
    if [ "$PLATFORM" != "macos" ] && command -v lspci >/dev/null 2>&1; then
        if lspci 2>/dev/null | grep -qi nvidia; then
            if [ "$PLATFORM" = "arch" ] && ! pacman -Qq lib32-nvidia-utils >/dev/null 2>&1; then
                warn "NVIDIA GPU detected but lib32-nvidia-utils is not installed — GL/EGL may fail from 32-bit Wine"
            fi
        fi
    fi

    printf '\nsummary: %s ok, %s failed.\n' "$_ok" "$_bad"
    [ "$_bad" -eq 0 ] && return 0 || return 1
}

# -----------------------------------------------------------------
# reset-cache (delegates to the patcher; also handles missing patcher)
# -----------------------------------------------------------------
run_reset_cache() {
    _patcher="$SCRIPT_DIR/bin/ssms-patcher"
    [ -x "$_patcher" ] || die "patcher not built; run install first."
    _ide="$WINEPREFIX/drive_c/Program Files (x86)/Microsoft SQL Server Management Studio 20/Common7/IDE"
    "$_patcher" reset-cache "$WINEPREFIX" --ssms-exe "$_ide/Ssms.exe"
}

# -----------------------------------------------------------------
# stage runner + state tracking (for --resume)
# -----------------------------------------------------------------
STATE_FILE=""
stage_done() { grep -Fxq "$1" "$STATE_FILE" 2>/dev/null; }
stage_mark() { echo "$1" >>"$STATE_FILE"; }
STAGE_FAILS=""
STAGE_OK=""

run_stage() {
    _name="$1"; shift
    if [ -n "$ONLY_STAGE" ] && [ "$ONLY_STAGE" != "$_name" ]; then return 0; fi
    if [ "$RESUME" -eq 1 ] && stage_done "$_name"; then
        log "stage $_name: already done (skipping — --resume)"
        return 0
    fi
    log "==> stage: $_name"
    if "$@"; then
        stage_mark "$_name"
        STAGE_OK="$STAGE_OK $_name"
        return 0
    else
        _rc=$?
        warn "stage $_name failed (rc=$_rc) — continuing (non-fatal)."
        STAGE_FAILS="$STAGE_FAILS $_name(rc=$_rc)"
        return 0
    fi
}

# -----------------------------------------------------------------
# stage: deps — install packages per platform
# -----------------------------------------------------------------
stage_deps() {
    case "$PLATFORM" in
        arch)
            if ! grep -qE '^[[:space:]]*\[multilib\]' /etc/pacman.conf; then
                err "[multilib] is disabled in /etc/pacman.conf."
                err "SSMS 20 is 32-bit PE32 — wine can't run it without multilib."
                err "Uncomment [multilib] and its Include line, then: sudo pacman -Syu"
                return 1
            fi
            _need=""
            for p in wine wine-mono wine-gecko winetricks unzip curl python; do
                pacman -Qq "$p" >/dev/null 2>&1 || _need="$_need $p"
            done
            if [ -n "$_need" ]; then
                log "missing pacman packages:$_need"
                if ask "Install via pacman?"; then
                    # shellcheck disable=SC2086
                    sudo pacman -S --needed $_need || return 1
                else
                    return 1
                fi
            fi ;;
        debian)
            command -v wine >/dev/null 2>&1 || warn "wine not installed — install wine-stable 11.x from WineHQ (see https://wiki.winehq.org/Ubuntu)"
            command -v winetricks >/dev/null 2>&1 || warn "winetricks missing (sudo apt install winetricks)"
            command -v unzip >/dev/null 2>&1 || warn "unzip missing (sudo apt install unzip)"
            command -v curl >/dev/null 2>&1 || warn "curl missing"
            command -v python3 >/dev/null 2>&1 || warn "python3 missing" ;;
        macos)
            command -v brew >/dev/null 2>&1 || die "Homebrew required (https://brew.sh)"
            for tool in winetricks git python3; do
                command -v "$tool" >/dev/null 2>&1 || { log "brew install $tool"; brew install "$tool"; }
            done
            if [ "$UNAME_M" = "arm64" ]; then
                warn "Apple Silicon: SSMS 20 is 32-bit x86. Without CrossOver (Wine 11 + Rosetta/GPTK)"
                warn "you will most likely fail here. See README."
            fi
            if ! command -v wine >/dev/null 2>&1; then
                for c in \
                    "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine" \
                    "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine"; do
                    if [ -x "$c" ]; then export PATH="$(dirname "$c"):$PATH"; break; fi
                done
                command -v wine >/dev/null 2>&1 || die "wine not found — install CrossOver or wine-stable via brew"
            fi ;;
        linux-other)
            warn "unknown distro — make sure wine 11+, winetricks, curl, unzip, python3 are installed" ;;
    esac
    command -v wine >/dev/null 2>&1 || die "wine still not on PATH"
    _wv="$(wine --version 2>/dev/null || echo unknown)"
    log "wine: $_wv"
    case "$_wv" in
        wine-1[1-9].*|wine-[2-9][0-9].*) : ;;
        *) warn "untested wine version ($_wv). Known-working: 11.0. Continuing anyway." ;;
    esac
    return 0
}

# -----------------------------------------------------------------
# stage: patcher — make sure ./bin/ssms-patcher exists
# -----------------------------------------------------------------
stage_patcher() {
    _p="$SCRIPT_DIR/bin/ssms-patcher"
    if [ -x "$_p" ] && "$_p" --help >/dev/null 2>&1; then
        log "patcher already built: $_p"
        return 0
    fi
    mkdir -p "$SCRIPT_DIR/bin"
    if download_patcher "$_p" "$PATCHER_RID"; then
        log "downloaded patcher: $_p"
        return 0
    fi
    warn "no matching release artifact for $PATCHER_RID; building from source."
    build_patcher "$_p" "$PATCHER_RID" || return 1
    log "built patcher: $_p"
    return 0
}

# -----------------------------------------------------------------
# stage: prefix — create prefix + winetricks verbs (idempotent)
# -----------------------------------------------------------------
DOTNET48_MARKER=""
stage_prefix() {
    log "using WINEPREFIX=$WINEPREFIX"
    if [ ! -d "$WINEPREFIX" ]; then
        log "creating fresh wine prefix..."
        wineboot --init >/dev/null 2>&1 || warn "wineboot returned non-zero"
        sleep 2
    fi

    DOTNET48_MARKER="$WINEPREFIX/.ssms-setup.dotnet48"

    # Deep .NET 4.8 detection: mscoreei.dll is native only when winetricks
    # dotnet48 has replaced Wine's stub. Marker file caches the decision.
    _dotnet_ok=0
    if [ -f "$DOTNET48_MARKER" ]; then
        _dotnet_ok=1
    else
        _mscoreei="$WINEPREFIX/drive_c/windows/system32/mscoreei.dll"
        if [ -f "$_mscoreei" ] && [ "$(wc -c <"$_mscoreei" 2>/dev/null || echo 0)" -gt 100000 ]; then
            _dotnet_ok=1
            : >"$DOTNET48_MARKER"
        fi
    fi

    if [ "$_dotnet_ok" = "1" ]; then
        log ".NET 4.8 already provisioned (skipping winetricks dotnet48)"
        # Still ensure the smaller verbs are applied; winetricks is idempotent.
        winetricks -q --force \
            win10 vcrun2022 gdiplus windowscodecs corefonts \
            d3dcompiler_43 d3dcompiler_47 d3dx9 msxml6 \
            >/dev/null 2>&1 || warn "winetricks returned non-zero (usually harmless)"
    else
        log "installing .NET 4.8 + friends via winetricks (slow — 5-10 min)..."
        winetricks -q --force \
            remove_mono \
            win10 \
            dotnet48 \
            vcrun2022 \
            gdiplus \
            windowscodecs \
            corefonts \
            d3dcompiler_43 d3dcompiler_47 d3dx9 \
            msxml6 \
            >/dev/null 2>&1 || warn "winetricks returned non-zero (may just mean 'already installed')"
        : >"$DOTNET48_MARKER"
    fi
    return 0
}

# -----------------------------------------------------------------
# stage: installer
# -----------------------------------------------------------------
IDE_DIR=""
stage_installer() {
    IDE_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Microsoft SQL Server Management Studio 20/Common7/IDE"
    if [ -f "$IDE_DIR/Ssms.exe" ]; then
        log "SSMS already installed at: $IDE_DIR"
        return 0
    fi
    [ -f "$INSTALLER" ] || { err "installer file missing: $INSTALLER"; return 1; }
    log "running SSMS installer (a Wine window may open; click through it)..."
    log "  installer: $INSTALLER"
    wine "$INSTALLER" /install /quiet /norestart 2>/dev/null \
        || warn "installer exit code non-zero (checking whether SSMS still landed)"
    [ -f "$IDE_DIR/Ssms.exe" ] || { err "SSMS did not install — try re-running the installer interactively"; return 1; }
    return 0
}

# -----------------------------------------------------------------
# stage: copy_dlls
# -----------------------------------------------------------------
stage_copy_dlls() {
    [ -d "$IDE_DIR" ] || IDE_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Microsoft SQL Server Management Studio 20/Common7/IDE"
    [ -d "$IDE_DIR" ] || { err "IDE dir missing: $IDE_DIR"; return 1; }
    log "installing bundled .NET dependency DLLs into IDE/..."
    for dll in "$SCRIPT_DIR"/dlls/*.dll; do
        [ -f "$dll" ] || continue
        cp -f "$dll" "$IDE_DIR/$(basename "$dll")"
        log "  + $(basename "$dll")"
    done
    return 0
}

# -----------------------------------------------------------------
# stage: redirects — inject bindingRedirects into both Ssms.exe.config
# -----------------------------------------------------------------
inject_redirects_into() {
    _cfg="$1"
    [ -f "$_cfg" ] || { warn "config not found (skipping): $_cfg"; return 0; }
    if grep -q 'SSMS-ON-WINE-REDIRECTS' "$_cfg" 2>/dev/null; then
        log "  (already injected) $_cfg"
        return 0
    fi
    log "  injecting redirects into $_cfg"
    python3 - "$_cfg" <<'PYEOF'
import sys
p = sys.argv[1]
with open(p, 'r', encoding='utf-8') as f: content = f.read()
redirects = '''
      <!-- SSMS-ON-WINE-REDIRECTS START -->
      <dependentAssembly>
        <assemblyIdentity name="System.Text.Json" publicKeyToken="cc7b13ffcd2ddd51" culture="neutral"/>
        <bindingRedirect oldVersion="0.0.0.0-7.0.0.1" newVersion="7.0.0.1"/>
      </dependentAssembly>
      <dependentAssembly>
        <assemblyIdentity name="Microsoft.Bcl.AsyncInterfaces" publicKeyToken="cc7b13ffcd2ddd51" culture="neutral"/>
        <bindingRedirect oldVersion="1.0.0.0-7.0.0.0" newVersion="7.0.0.0"/>
      </dependentAssembly>
      <dependentAssembly>
        <assemblyIdentity name="System.Text.Encodings.Web" publicKeyToken="cc7b13ffcd2ddd51" culture="neutral"/>
        <bindingRedirect oldVersion="0.0.0.0-7.0.0.0" newVersion="7.0.0.0"/>
      </dependentAssembly>
      <dependentAssembly>
        <assemblyIdentity name="System.Memory" publicKeyToken="cc7b13ffcd2ddd51" culture="neutral"/>
        <bindingRedirect oldVersion="0.0.0.0-4.0.1.2" newVersion="4.0.1.2"/>
      </dependentAssembly>
      <dependentAssembly>
        <assemblyIdentity name="System.Security.AccessControl" publicKeyToken="b03f5f7f11d50a3a" culture="neutral"/>
        <bindingRedirect oldVersion="0.0.0.0-5.0.0.0" newVersion="5.0.0.0"/>
      </dependentAssembly>
      <dependentAssembly>
        <assemblyIdentity name="System.IO.FileSystem.AccessControl" publicKeyToken="b03f5f7f11d50a3a" culture="neutral"/>
        <bindingRedirect oldVersion="0.0.0.0-5.0.0.0" newVersion="5.0.0.0"/>
      </dependentAssembly>
      <dependentAssembly>
        <assemblyIdentity name="System.Security.Principal.Windows" publicKeyToken="b03f5f7f11d50a3a" culture="neutral"/>
        <bindingRedirect oldVersion="0.0.0.0-5.0.0.0" newVersion="5.0.0.0"/>
      </dependentAssembly>
      <dependentAssembly>
        <assemblyIdentity name="System.Threading.Tasks.Dataflow" publicKeyToken="b03f5f7f11d50a3a" culture="neutral"/>
        <bindingRedirect oldVersion="0.0.0.0-4.6.3.0" newVersion="4.5.24.0"/>
      </dependentAssembly>
      <!-- SSMS-ON-WINE-REDIRECTS END -->
'''
if '</assemblyBinding>' in content:
    content = content.replace('</assemblyBinding>', redirects + '   </assemblyBinding>', 1)
elif '<runtime>' in content:
    inject = '<assemblyBinding xmlns="urn:schemas-microsoft-com:asm.v1">' + redirects + '</assemblyBinding>'
    content = content.replace('<runtime>', '<runtime>' + inject, 1)
else:
    content = content.replace('</configuration>',
        '<runtime><assemblyBinding xmlns="urn:schemas-microsoft-com:asm.v1">' + redirects + '</assemblyBinding></runtime></configuration>', 1)
with open(p, 'w', encoding='utf-8') as f: f.write(content)
print("OK:", p)
PYEOF
}

stage_redirects() {
    [ -d "$IDE_DIR" ] || IDE_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Microsoft SQL Server Management Studio 20/Common7/IDE"
    _cfg_ide="$IDE_DIR/Ssms.exe.config"
    _user="$(id -un 2>/dev/null || whoami)"
    _cfg_appdata="$WINEPREFIX/drive_c/users/$_user/AppData/Local/Microsoft/SQL Server Management Studio/20.0_IsoShell/Ssms.exe.config"
    inject_redirects_into "$_cfg_ide" || true
    inject_redirects_into "$_cfg_appdata" || true
    return 0
}

# -----------------------------------------------------------------
# stage: patch_gifs / patch_nav (non-fatal)
# -----------------------------------------------------------------
stage_patch_gifs() {
    [ -x "$SCRIPT_DIR/bin/ssms-patcher" ] || { err "patcher missing"; return 1; }
    [ -d "$IDE_DIR" ] || IDE_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Microsoft SQL Server Management Studio 20/Common7/IDE"
    "$SCRIPT_DIR/bin/ssms-patcher" patch-gifs "$IDE_DIR"
}

stage_patch_nav() {
    [ -x "$SCRIPT_DIR/bin/ssms-patcher" ] || { err "patcher missing"; return 1; }
    [ -d "$IDE_DIR" ] || IDE_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Microsoft SQL Server Management Studio 20/Common7/IDE"
    "$SCRIPT_DIR/bin/ssms-patcher" patch-nav "$IDE_DIR"
}

# -----------------------------------------------------------------
# stage: reset_cache (after patches, so VS Shell rebuilds MEF state)
# -----------------------------------------------------------------
stage_reset_cache() {
    [ -x "$SCRIPT_DIR/bin/ssms-patcher" ] || return 0
    [ -d "$IDE_DIR" ] || IDE_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Microsoft SQL Server Management Studio 20/Common7/IDE"
    "$SCRIPT_DIR/bin/ssms-patcher" reset-cache "$WINEPREFIX" \
        --ssms-exe "$IDE_DIR/Ssms.exe" --skip-update
    # We intentionally skip /updateconfiguration here — it can hang under
    # Wine on a fresh prefix. The user can run it later:
    #   ./setup-ssms.sh reset-cache
}

# -----------------------------------------------------------------
# stage: launcher — .desktop on Linux, .command on macOS
# -----------------------------------------------------------------
stage_launcher() {
    [ -d "$IDE_DIR" ] || IDE_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Microsoft SQL Server Management Studio 20/Common7/IDE"
    if [ "$PLATFORM" = "macos" ]; then
        mkdir -p "$HOME/Applications"
        _launcher="$HOME/Applications/SSMS 20 (Wine).command"
        _wine_bin="$(command -v wine)"
        cat > "$_launcher" <<EOF
#!/usr/bin/env bash
export WINEPREFIX="$WINEPREFIX"
export PATH="$(dirname "$_wine_bin"):\$PATH"
exec "$_wine_bin" "C:\\\\Program Files (x86)\\\\Microsoft SQL Server Management Studio 20\\\\Common7\\\\IDE\\\\Ssms.exe"
EOF
        chmod +x "$_launcher"
        log "launcher written: $_launcher"
    else
        _desktop="$HOME/.local/share/applications/ssms-on-wine.desktop"
        mkdir -p "$(dirname "$_desktop")"
        cat > "$_desktop" <<EOF
[Desktop Entry]
Name=SQL Server Management Studio 20 (Wine)
Comment=Run 'kinit' on the host before launching if using Kerberos
Exec=env WINEPREFIX=$WINEPREFIX wine "C:\\\\Program Files (x86)\\\\Microsoft SQL Server Management Studio 20\\\\Common7\\\\IDE\\\\Ssms.exe"
Type=Application
Terminal=false
Icon=applications-database
Categories=Development;Database;
StartupWMClass=ssms.exe
EOF
        log "launcher written: $_desktop"
    fi
    return 0
}

# -----------------------------------------------------------------
# main dispatch
# -----------------------------------------------------------------
case "$MODE" in
    doctor)      run_doctor; exit $? ;;
    reset-cache) run_reset_cache; exit $? ;;
esac

# install-mode: everything below.

if [ -z "$INSTALLER" ]; then
    prompt_download
    exit 0
fi
[ -f "$INSTALLER" ] || die "installer file not found: $INSTALLER"

STATE_FILE="$WINEPREFIX/.ssms-setup.state"
mkdir -p "$WINEPREFIX" 2>/dev/null || true
: >>"$STATE_FILE" 2>/dev/null || STATE_FILE="/tmp/.ssms-setup.state.$$"

# stages in order
run_stage deps            stage_deps
run_stage patcher         stage_patcher
run_stage prefix          stage_prefix
run_stage installer       stage_installer
run_stage copy_dlls       stage_copy_dlls
run_stage redirects       stage_redirects
run_stage patch_gifs      stage_patch_gifs
run_stage patch_nav       stage_patch_nav
run_stage reset_cache     stage_reset_cache
run_stage launcher        stage_launcher

# -----------------------------------------------------------------
# summary
# -----------------------------------------------------------------
printf '\n'
printf '=====================================================================\n'
printf '  Setup summary\n'
printf '=====================================================================\n'
if [ -n "$STAGE_OK" ]; then
    printf '  OK    :%s\n' "$STAGE_OK"
fi
if [ -n "$STAGE_FAILS" ]; then
    printf '\033[1;33m  FAIL  :%s\033[0m\n' "$STAGE_FAILS"
    printf '\n'
    printf '  Failed stages did NOT abort the install. Common outcomes:\n'
    printf '    * patch_gifs failed → some dialogs will throw\n'
    printf '        "Parameter is not valid. (System.Drawing)". Re-run:\n'
    printf '            ./setup-ssms.sh --only patch_gifs %s %s\n' "$INSTALLER" "$WINEPREFIX"
    printf '    * patch_nav failed  → Object Explorer will show static folders only.\n'
    printf '        Inspect layout:  bin/ssms-patcher locate <IDE_DIR>\n'
    printf '    * reset_cache failed → run manually:\n'
    printf '            ./setup-ssms.sh reset-cache %s\n' "$WINEPREFIX"
fi
printf '\n'
printf '  Prefix    : %s\n' "$WINEPREFIX"
printf '  Launcher  : %s\n' \
    "$( [ "$PLATFORM" = macos ] && printf '~/Applications/SSMS 20 (Wine).command' \
        || printf '%s' '~/.local/share/applications/ssms-on-wine.desktop' )"
printf '\n'
printf '  Kerberos? Get a ticket on the host BEFORE launching SSMS:\n'
printf '      kinit your.username@YOURREALM.EXAMPLE.COM\n'
printf '\n'
printf '  Diagnostics:  ./setup-ssms.sh doctor\n'
printf '  Verify:       ./bin/ssms-patcher verify "%s/drive_c/Program Files (x86)/Microsoft SQL Server Management Studio 20/Common7/IDE"\n' "$WINEPREFIX"
printf '=====================================================================\n'

# Non-zero exit if any stage failed, so CI can spot it.
[ -z "$STAGE_FAILS" ] || exit 3
exit 0
