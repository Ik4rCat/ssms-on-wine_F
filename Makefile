.PHONY: all build build-linux build-osx-x64 build-osx-arm64 clean run-verify help test

BIN      := bin/ssms-patcher
IDE_DIR  ?= $(HOME)/.wine-ssms/drive_c/Program Files (x86)/Microsoft SQL Server Management Studio 20/Common7/IDE
RID      ?= linux-x64

# GNU stat uses -c%s, BSD stat uses -f%z; wc -c is portable.
FILESIZE  = $$(wc -c <"$$1" | tr -d ' ')

# Building requires the workload resolver to be disabled on machines
# where dotnet workloads are half-installed (common in CI).
DOTNET := MSBuildEnableWorkloadResolver=false dotnet

all: build

help:
	@echo "targets:"
	@echo "  make build              — publish ./bin/ssms-patcher for the host RID ($(RID))"
	@echo "  make build-linux        — force linux-x64"
	@echo "  make build-osx-x64      — force osx-x64"
	@echo "  make build-osx-arm64    — force osx-arm64"
	@echo "  make clean              — remove build artefacts"
	@echo "  make run-verify         — run ssms-patcher verify against an installed SSMS"
	@echo "  make test               — run patcher unit tests (tests/fixtures)"

build: $(BIN)

$(BIN): src/Program.cs src/PathResolver.cs src/GifPatcher.cs src/NavPatcher.cs src/CacheReset.cs src/ActivityLog.cs src/ssms-patcher.csproj
	@command -v dotnet >/dev/null 2>&1 || { \
	  echo "error: dotnet SDK not found. Install dotnet-sdk-10.0 first."; exit 1; }
	@mkdir -p bin
	cd src && $(DOTNET) publish -c Release -r $(RID) --self-contained -o ../bin
	@rm -f bin/*.pdb bin/ssms-patcher.dll
	@sz=$$(wc -c <"$(BIN)" | tr -d ' '); \
	 if command -v numfmt >/dev/null 2>&1; then sz=$$(printf '%s' "$$sz" | numfmt --to=iec); fi; \
	 echo "built: $(BIN)  ($$sz)"

build-linux:
	$(MAKE) RID=linux-x64 build

build-osx-x64:
	$(MAKE) RID=osx-x64 build

build-osx-arm64:
	$(MAKE) RID=osx-arm64 build

clean:
	rm -rf bin src/bin src/obj

run-verify:
	@test -x $(BIN) || { echo "run 'make build' first"; exit 1; }
	$(BIN) verify "$(IDE_DIR)"

test:
	@test -d tests || { echo "no tests/ directory yet"; exit 0; }
	cd tests && $(DOTNET) test
