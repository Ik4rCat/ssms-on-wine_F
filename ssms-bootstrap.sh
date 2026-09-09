#!/usr/bin/env bash
#
# ssms-bootstrap.sh — кроссплатформенная обёртка вокруг WilhelmZA/ssms-on-wine.
#
# Что делает:
#   1. определяет ОС (Arch Linux / macOS) и доставляет зависимости
#   2. находит подходящий бинарник wine
#   3. собирает ssms-patcher под нативную архитектуру (на Linux — качает готовый)
#   4. отдаёт управление оригинальному setup-ssms.sh
#   5. на macOS дополнительно кладёт .command-лаунчер
#
# Использование:
#   ./ssms-bootstrap.sh /path/to/SSMS-Setup-ENU.exe [WINEPREFIX]
#
set -euo pipefail

INSTALLER="${1:-}"
WINEPREFIX_ARG="${2:-$HOME/.wine-ssms}"
REPO_URL="https://github.com/WilhelmZA/ssms-on-wine.git"
WORKDIR="${SSMS_WORKDIR:-$HOME/.local/share/ssms-on-wine}"

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }
ask()  {
    local prompt="$1"
    [ -t 0 ] || return 0            # неинтерактивный запуск — считаем «да»
    read -r -p "$prompt [Y/n] " a
    case "$a" in [Nn]*) return 1 ;; *) return 0 ;; esac
}

# ---------------------------------------------------------------------
# аргументы
# ---------------------------------------------------------------------
if [ -z "$INSTALLER" ]; then
    cat <<'EOF'
Использование: ./ssms-bootstrap.sh /path/to/SSMS-Setup-ENU.exe [WINEPREFIX]

SSMS-Setup-ENU.exe (версия 20.x) нужно скачать самому со страницы Microsoft:
  https://learn.microsoft.com/en-us/sql/ssms/download-sql-server-management-studio-ssms
Скрипт его не тянет — лицензия MS не позволяет распространять.
EOF
    exit 1
fi
[ -f "$INSTALLER" ] || die "установщик не найден: $INSTALLER"
INSTALLER="$(cd "$(dirname "$INSTALLER")" && pwd)/$(basename "$INSTALLER")"

# ---------------------------------------------------------------------
# определение платформы
# ---------------------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
    Linux)
        if command -v pacman >/dev/null 2>&1; then PLATFORM=arch
        else PLATFORM=linux-other; fi ;;
    Darwin) PLATFORM=macos ;;
    *) die "неподдерживаемая ОС: $OS" ;;
esac
log "платформа: $PLATFORM ($ARCH)"

case "$PLATFORM-$ARCH" in
    macos-arm64)  DOTNET_RID=osx-arm64  ;;
    macos-x86_64) DOTNET_RID=osx-x64    ;;
    *-x86_64)     DOTNET_RID=linux-x64  ;;
    *) die "неподдерживаемая архитектура: $ARCH" ;;
esac

# ---------------------------------------------------------------------
# зависимости: Arch
# ---------------------------------------------------------------------
setup_arch() {
    if ! grep -qE '^\s*\[multilib\]' /etc/pacman.conf; then
        warn "репозиторий [multilib] выключен в /etc/pacman.conf."
        warn "SSMS 20 — 32-битное приложение, без multilib wine его не запустит."
        warn "Раскомментируй [multilib] и Include, затем: sudo pacman -Syu"
        die  "включи multilib и запусти скрипт заново."
    fi

    local need=()
    for p in wine wine-mono wine-gecko winetricks git unzip curl python; do
        pacman -Qq "$p" >/dev/null 2>&1 || need+=("$p")
    done

    if [ ${#need[@]} -gt 0 ]; then
        log "не хватает пакетов: ${need[*]}"
        if ask "Поставить их через pacman?"; then
            sudo pacman -S --needed "${need[@]}"
        else
            die "без этих пакетов дальше нельзя."
        fi
    else
        log "все пакеты на месте."
    fi

    # dotnet нужен только если придётся собирать патчер локально
    WINE_BIN="$(command -v wine)"
}

# ---------------------------------------------------------------------
# зависимости: macOS
# ---------------------------------------------------------------------
setup_macos() {
    command -v brew >/dev/null 2>&1 || die "нужен Homebrew: https://brew.sh"

    if [ "$ARCH" = "arm64" ]; then
        if ! /usr/bin/pgrep -q oahd 2>/dev/null && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
            log "ставлю Rosetta 2..."
            softwareupdate --install-rosetta --agree-to-license
        fi
        warn "Apple Silicon: SSMS 20 — 32-битный x86. Штатная сборка wine-stable"
        warn "32-битный код здесь обычно не тянет. Рабочий вариант — CrossOver"
        warn "(в нём Wine 11 + трансляция 32-бит через Rosetta/GPTK)."
        warn "Если CrossOver не установлен — скрипт всё равно попробует, но"
        warn "шансы на успех заметно ниже, чем на Intel-маке или Linux."
    fi

    # ищем wine: сначала CrossOver, потом обычные каски
    # (без массивов — в macOS штатный bash 3.2)
    WINE_BIN=""
    for c in \
        "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine" \
        "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine" \
        "/Applications/Wine Crossover.app/Contents/Resources/wine/bin/wine"
    do
        [ -x "$c" ] && { WINE_BIN="$c"; break; }
    done
    [ -z "$WINE_BIN" ] && WINE_BIN="$(command -v wine || true)"

    if [ -z "$WINE_BIN" ]; then
        log "wine не найден."
        if ask "Поставить wine-stable через brew?"; then
            brew install --cask --no-quarantine wine-stable
            WINE_BIN="$(command -v wine || true)"
            [ -z "$WINE_BIN" ] && WINE_BIN="/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine"
        else
            die "wine обязателен."
        fi
    fi
    log "wine: $WINE_BIN"

    for f in winetricks git; do
        command -v "$f" >/dev/null 2>&1 || {
            log "ставлю $f..."; brew install "$f"; }
    done
    command -v python3 >/dev/null 2>&1 || { log "ставлю python..."; brew install python; }

    # wine должен быть в PATH — оригинальный скрипт зовёт его по имени
    local winedir
    winedir="$(dirname "$WINE_BIN")"
    export PATH="$winedir:$PATH"
}

case "$PLATFORM" in
    arch)  setup_arch ;;
    macos) setup_macos ;;
    linux-other)
        warn "не Arch — зависимости ставь сам: wine 11+, winetricks, git, unzip, python3"
        WINE_BIN="$(command -v wine)" || die "wine не найден." ;;
esac

WINE_VER="$("$WINE_BIN" --version 2>/dev/null || echo unknown)"
log "версия wine: $WINE_VER"
case "$WINE_VER" in
    wine-1[1-9].*|wine-[2-9][0-9].*) : ;;
    *) warn "апстрим тестировался на wine-11.0. У тебя $WINE_VER — может не взлететь." ;;
esac

# ---------------------------------------------------------------------
# репозиторий
# ---------------------------------------------------------------------
if [ -d "$WORKDIR/.git" ]; then
    log "обновляю $WORKDIR..."
    git -C "$WORKDIR" pull --ff-only || warn "git pull не прошёл, работаю с локальной копией."
else
    log "клонирую в $WORKDIR..."
    mkdir -p "$(dirname "$WORKDIR")"
    git clone --depth 1 "$REPO_URL" "$WORKDIR"
fi

# ---------------------------------------------------------------------
# патчер
# ---------------------------------------------------------------------
PATCHER="$WORKDIR/bin/ssms-patcher"

build_patcher() {
    command -v dotnet >/dev/null 2>&1 || {
        if [ "$PLATFORM" = macos ]; then
            log "ставлю dotnet-sdk..."; brew install --cask dotnet-sdk
        else
            log "нужен .NET SDK 10+"
            ask "Поставить dotnet-sdk через pacman?" && sudo pacman -S --needed dotnet-sdk || die "нет dotnet."
        fi
    }
    log "собираю ssms-patcher под $DOTNET_RID (пара минут)..."
    mkdir -p "$WORKDIR/bin"
    ( cd "$WORKDIR/src" && dotnet publish -c Release -r "$DOTNET_RID" --self-contained -o "$WORKDIR/bin" )
    rm -f "$WORKDIR"/bin/*.pdb "$WORKDIR"/bin/ssms-patcher.dll
    chmod +x "$PATCHER"
}

if [ -x "$PATCHER" ] && "$PATCHER" --help >/dev/null 2>&1; then
    log "патчер уже собран и запускается."
else
    rm -f "$PATCHER"
    if [ "$DOTNET_RID" = "linux-x64" ]; then
        log "качаю готовый патчер из GitHub Releases..."
        mkdir -p "$WORKDIR/bin"
        if curl -sSL -f -o "$PATCHER" \
            "https://github.com/WilhelmZA/ssms-on-wine/releases/latest/download/ssms-patcher-linux-x64"; then
            chmod +x "$PATCHER"
        else
            warn "скачать не вышло — собираю из исходников."
            build_patcher
        fi
    else
        log "готовых сборок под $DOTNET_RID нет (в релизах только Linux ELF) — собираю сам."
        build_patcher
    fi
fi
[ -x "$PATCHER" ] || die "патчер так и не появился: $PATCHER"

# ---------------------------------------------------------------------
# основной установщик
# ---------------------------------------------------------------------
log "запускаю setup-ssms.sh (10–15 минут: .NET 4.8 + инсталлятор SSMS)..."
export WINEARCH=win64
"$WORKDIR/setup-ssms.sh" "$INSTALLER" "$WINEPREFIX_ARG"

# ---------------------------------------------------------------------
# лаунчер под macOS (на Linux .desktop уже создан апстримом)
# ---------------------------------------------------------------------
if [ "$PLATFORM" = macos ]; then
    rm -f "$HOME/.local/share/applications/ssms-on-wine.desktop"
    mkdir -p "$HOME/Applications"
    LAUNCHER="$HOME/Applications/SSMS 20 (Wine).command"
    cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
export WINEPREFIX="$WINEPREFIX_ARG"
export PATH="$(dirname "$WINE_BIN"):\$PATH"
exec "$WINE_BIN" "C:\\\\Program Files (x86)\\\\Microsoft SQL Server Management Studio 20\\\\Common7\\\\IDE\\\\Ssms.exe"
EOF
    chmod +x "$LAUNCHER"
    log "лаунчер: $LAUNCHER"
fi

cat <<EOF

=====================================================================
  Готово.
=====================================================================

Префикс: $WINEPREFIX_ARG

Запуск вручную:
  WINEPREFIX="$WINEPREFIX_ARG" "$WINE_BIN" \\
    "C:\\Program Files (x86)\\Microsoft SQL Server Management Studio 20\\Common7\\IDE\\Ssms.exe"

Для Windows-аутентификации сначала на хосте: kinit user@REALM
Для SQL-аутентификации ничего дополнительно не нужно.

Диагностика:
  "$PATCHER" verify "<IDE_DIR>"
  "$PATCHER" patch-gifs "<IDE_DIR>"
  "$PATCHER" restore "<IDE_DIR>"

где IDE_DIR = $WINEPREFIX_ARG/drive_c/Program Files (x86)/Microsoft SQL Server Management Studio 20/Common7/IDE
=====================================================================
EOF
