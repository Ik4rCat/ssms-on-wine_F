# SSMS 20 on Wine — installer + patcher

[![lint](https://github.com/Ik4rCat/ssms-on-wine_F/actions/workflows/lint.yml/badge.svg)](https://github.com/Ik4rCat/ssms-on-wine_F/actions/workflows/lint.yml)
[![build](https://github.com/Ik4rCat/ssms-on-wine_F/actions/workflows/build.yml/badge.svg)](https://github.com/Ik4rCat/ssms-on-wine_F/actions/workflows/build.yml)

Installer + binary patcher that gets **SQL Server Management Studio 20.2.1**
running under Wine on Linux and (best-effort) macOS. Automates the wine
prefix setup, the SSMS installer, the .NET redirects, the GIF→PNG patch,
the NavigationService patch, and the launcher.

**Fork status.** This is a fork of [`WilhelmZA/ssms-on-wine`](https://github.com/WilhelmZA/ssms-on-wine).
Upstream targeted Ubuntu 24.04 + wine-stable 11.0 + an early SSMS 20 build;
this fork addresses breakage on Arch, macOS, and later SSMS 20.x layouts
(20.2.1 moved Explorer.dll into `Extensions/Application/`).

## Compatibility matrix

| SSMS build       | Ubuntu 24.04 + wine 11 | Arch + wine 11 | macOS (CrossOver / wine-stable) |
| ---------------- | ---------------------- | -------------- | ------------------------------- |
| 20.0.x (flat)    | ✅ tested (upstream)    | ✅ tested       | 🟡 unverified                    |
| **20.2.1**       | ✅ tested               | ✅ tested       | 🟡 Apple Silicon: needs CrossOver; Intel: unverified |
| 21.x, 22.x       | ❌ VS Installer bootstrapper won't run under Wine |

## Quickstart

```sh
# 1. Grab an SSMS-Setup-ENU.exe — MS EULA forbids redistribution, so this
#    script cannot download it. Running the installer without an argument
#    prints the download URL and opens it in your default browser:
./setup-ssms.sh

# 2. Then rerun pointing at the downloaded file:
./setup-ssms.sh /path/to/SSMS-Setup-ENU.exe

# 3. Optional: use a custom prefix
./setup-ssms.sh /path/to/SSMS-Setup-ENU.exe /custom/prefix
```

Runs 10–15 minutes end-to-end. Most of it is `.NET 4.8` via winetricks
and the Microsoft SSMS installer; the binary patches are fast.

The MS installer URL used by the browser opener is:
`https://go.microsoft.com/fwlink/?linkid=2313753&clcid=0x409` — that's
the last SSMS release (20.2.1) that ships as a standalone MSI-style EXE.

### Non-fatal stages

Patch stages (`patch_gifs`, `patch_nav`, `reset_cache`) never abort the
install. Failures are logged, the launcher is still created, and a
per-stage summary prints at the end. Re-run individual stages with:

```sh
./setup-ssms.sh --only patch_gifs /path/to/SSMS-Setup-ENU.exe
./setup-ssms.sh --only patch_nav  /path/to/SSMS-Setup-ENU.exe
./setup-ssms.sh --resume          /path/to/SSMS-Setup-ENU.exe
```

`--resume` skips stages already recorded in `$WINEPREFIX/.ssms-setup.state`.

### Diagnostics

```sh
./setup-ssms.sh doctor                # host / prefix / patcher health checklist
./setup-ssms.sh reset-cache           # wipe ComponentModelCache
./bin/ssms-patcher locate <IDE_DIR>   # print SSMS version + resolved layout
./bin/ssms-patcher verify <IDE_DIR>   # list which DLLs are currently patched
```

## Prerequisites by platform

### Ubuntu 24.04

```sh
# WineHQ noble repo (see https://wiki.winehq.org/Ubuntu), then:
sudo apt install wine-stable winetricks unzip curl python3
```

### Arch Linux

`[multilib]` **must be enabled** in `/etc/pacman.conf` — SSMS 20 is a 32-bit
PE32 executable; without multilib wine can't run it. The `deps` stage of
`setup-ssms.sh` refuses to continue if multilib is off.

```sh
sudo pacman -S wine wine-mono wine-gecko winetricks unzip curl python
# lib32-unixodbc is recommended (SSMS uses ANSI ODBC entry points)
sudo pacman -S lib32-unixodbc
# on NVIDIA hosts:
sudo pacman -S lib32-nvidia-utils
```

### macOS

- **Homebrew** for the tooling: `brew install --cask wine-stable && brew install winetricks python3`.
- **Apple Silicon**: stock wine-stable can't run 32-bit x86 code reliably.
  The realistic option is CrossOver (which bundles Wine 11 + Rosetta/GPTK
  translation). The script searches for wine at
  `/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine`
  before falling back to Homebrew's cask.
- Launcher is written to `~/Applications/SSMS 20 (Wine).command` (double-clickable).

## Kerberos

Windows Authentication uses the ticket cache your **host** owns —
Wine's SSPI stack picks it up automatically. Before launching SSMS:

```sh
kinit your.username@YOURREALM.EXAMPLE.COM
klist    # verify
```

No MIT Kerberos install is needed inside the prefix.

## What actually happens under the hood

Prefix setup (via winetricks):

- `remove_mono` → then `dotnet48` (must go before the SSMS installer)
- `win10`, `vcrun2022`, `gdiplus`, `windowscodecs`, `corefonts`
- `d3dcompiler_43`, `d3dcompiler_47`, `d3dx9`, `msxml6`

The `prefix` stage is idempotent — subsequent runs check for a native
`mscoreei.dll` and skip the slow `dotnet48` re-install.

Bundled `.NET` DLLs dropped into `IDE/` (SSMS asks for these but doesn't
ship them):
`System.Text.Json`, `Microsoft.Bcl.AsyncInterfaces`, `System.Text.Encodings.Web`,
`System.Memory`, `System.Security.AccessControl`, `System.IO.FileSystem.AccessControl`,
`System.Security.Principal.Windows`.

Binding redirects injected into both `Ssms.exe.config` files (IDE + AppData).

Binary patches (all reversible; backups sit next to the originals):

- **GIF → PNG resource swap** across DLLs under `Common7/IDE/`. Wine 11's
  GIF decoder is broken; PNG payloads with the same byte length work
  around it. Backups: `*.orig-gif`. By default DLLs that live next to a
  `.pkgdef` (VS package assemblies) are **skipped** because Cecil-rewriting
  invalidates the strong-name hash VS Shell caches — see problem #2
  in `claude_task.md`. Use `--force-strong` if you know what you're
  doing.
- **NavigationService no-op** in
  `Microsoft.SqlServer.Management.SqlStudio.Explorer.dll`. The patcher
  finds this DLL under `Extensions/Application/` (20.2.1) or at the
  IDE root (older 20.x). Backup: `*.preinject`.

Post-patch, `ComponentModelCache` is wiped so VS Shell rebuilds its MEF
graph from the patched DLLs instead of the cached "broken" state.

## Acceptance checklist (what to smoke-test after install)

Run through this after launching SSMS to confirm the install is really
working, not merely opening the window:

- [ ] Connect dialog opens; Windows Authentication → server → connect succeeds
- [ ] Object Explorer expands `Databases` → user DBs, `Security`, `Server Objects`
- [ ] Expanding a database issues real SMO queries (visible in server-side traces)
- [ ] Right-click a table → `Properties` opens the properties dialog
- [ ] `New Query` opens a query editor tab; F5 executes; result grid shows rows
- [ ] `View → Output → Object Explorer` shows no red-flag exceptions
- [ ] Table Designer opens on an existing table

## What does not work

- **Azure connections** of any kind (SQL Database, Managed Instance,
  Synapse, Fabric) — untested / expected to fail.
- **SSIS / SSAS / SSRS designers** — some rely on unpatched GIFs in
  Report Viewer / Mashup client DLLs.
- **Always On / HADR** dialogs.
- **Database Engine Tuning Advisor** (separate tool in the bundle).
- **Activity Monitor** with performance counters (Wine perf hooks miss).
- **SSMS 21 / 22** — those ship as VS Installer bootstrappers
  (`vs_SSMS.exe`) which Wine cannot execute.

See `APPDB-ENTRY.txt` for the full write-up.

## Troubleshooting

**Object Explorer shows only "System Databases" and "Database Snapshots".**
The NavigationService patch didn't apply. Check:
```sh
./bin/ssms-patcher locate  "$IDE_DIR"   # is Explorer.dll where we expected?
./bin/ssms-patcher verify  "$IDE_DIR"   # any *.preinject backups?
./setup-ssms.sh --only patch_nav /path/to/SSMS-Setup-ENU.exe
```

**Dialogs throw `Parameter is not valid. (System.Drawing)`.**
A GIF wasn't patched. Re-run:
```sh
./setup-ssms.sh --only patch_gifs /path/to/SSMS-Setup-ENU.exe
```

**A "package did not load correctly" error mentioning `SqlStudioExplorer`.**
This is the strong-name / package-hash cache problem — a re-patch after
wiping `ComponentModelCache` usually fixes it:
```sh
./setup-ssms.sh reset-cache
```

**Object Explorer errors are hidden.**
`View → Output → Object Explorer` in SSMS exposes the caught-and-swallowed
exceptions.

**Deeper diagnostics.** SSMS writes a VS ActivityLog at
`$WINEPREFIX/drive_c/users/<you>/AppData/Roaming/Microsoft/AppEnv/15.0/ActivityLog.xml`
(UTF-16 LE). The patcher parses it and prints only failures:
```sh
./bin/ssms-patcher parse-log \
  "$WINEPREFIX/drive_c/users/$USER/AppData/Roaming/Microsoft/AppEnv/15.0/ActivityLog.xml"
```

**Revert everything.**
```sh
./bin/ssms-patcher restore "$IDE_DIR"
```
Restore a single file:
```sh
./bin/ssms-patcher restore "$IDE_DIR" --file \
  "$IDE_DIR/Extensions/Application/Microsoft.SqlServer.Management.SqlStudio.Explorer.dll"
```

## Uninstall

```sh
./bin/ssms-patcher restore "$IDE_DIR"
rm -rf ~/.wine-ssms
rm -f  ~/.local/share/applications/ssms-on-wine.desktop
rm -f  "$HOME/Applications/SSMS 20 (Wine).command"   # macOS
```

## Layout

```
.
├── setup-ssms.sh              main installer (all platforms)
├── Makefile                   build targets for the patcher
├── src/                       C# sources for ssms-patcher
│   ├── Program.cs             CLI dispatcher
│   ├── PathResolver.cs        recursive locate + version detect
│   ├── GifPatcher.cs          patch-gifs + skip-heuristics
│   ├── NavPatcher.cs          patch-nav
│   ├── CacheReset.cs          reset-cache
│   └── ActivityLog.cs         parse-log
├── dlls/                      bundled .NET dependency DLLs
├── tests/                     synthetic fixtures + smoke tests
│   ├── run.sh                 exercises the CLI contract end-to-end
│   └── testasm/               tiny .NET library with a real embedded GIF
├── .github/workflows/         lint / build / release
└── APPDB-ENTRY.txt            WineHQ AppDB write-up (root-cause detail)
```

## Building the patcher yourself

```sh
# Requires the .NET 10 SDK.
make build                    # host RID
make build-linux              # explicit linux-x64
make build-osx-x64
make build-osx-arm64
```

The build embeds the .NET 10 runtime; the resulting binary is ~75 MB
self-contained.

## Contributing / issues

Report at <https://github.com/Ik4rCat/ssms-on-wine_F/issues>.
Please include:

- `wine --version`
- `./setup-ssms.sh doctor` output
- `./bin/ssms-patcher locate "$IDE_DIR"` output
- The SSMS `View → Output → Object Explorer` pane if it's an OE issue
- `./bin/ssms-patcher parse-log <ActivityLog.xml>` if it's a package-load issue

## License

Patcher code (`src/`, `tests/`) is MIT. Bundled `.NET` DLLs in `dlls/` are
redistributable per the .NET Foundation / MS license. SSMS itself is
governed by Microsoft's EULA — you provide your own `SSMS-Setup-ENU.exe`.
