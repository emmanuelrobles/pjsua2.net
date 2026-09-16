# pjsua2.net — build pjsua2 and the SWIG C# bindings for multiple runtimes,
# then pack a NuGet package.
#
# Pipeline:
#   1. run SWIG once to generate the C# bindings + native wrapper (pjsua2_wrap.cpp)
#   2. for each RID: configure + build the pjproject submodule (with -fPIC),
#      compile the wrapper and link the native library into runtimes/<rid>/native/
#   3. dotnet build / pack the pjsua2.net project into a NuGet package
#
# Targets:
#   all            build native libraries + managed assembly (default)
#   pack           build everything and produce the .nupkg in $(OUT_DIR)
#   native         generate bindings + native libraries for every RID
#   configure      run pjproject's ./configure for the host target
#   pjproject      build the pjproject static libraries for the host target
#   dotnet-build   dotnet build the managed project
#   clean          remove generated bindings/native/nuget artifacts
#   distclean      clean + fully clean the pjproject tree
#
# Overridable:
#   CONFIGURATION  dotnet build configuration (default: Release)
#   JOBS           number of parallel pjproject build jobs (default: nproc)
#   NAMESPACE      C# namespace for the bindings (default: pjsua2)
#   OPENSSL_VERSION OpenSSL release to cross-build for the cross targets
#   RIDS           space-separated list of runtimes to build
#                  (default: linux-x64 linux-arm64 win-x64 win-x86)

PJDIR        := pjproject
MAKE         ?= make
JOBS         ?= $(shell nproc 2>/dev/null || echo 4)
CONFIGURATION ?= Release
NAMESPACE    ?= pjsua2

# ---------------------------------------------------------------------------
# OpenSSL. Native targets link against OpenSSL provided by the build host,
# autodetected by pjproject's ./configure from its default include/lib paths:
#   linux-x64  system OpenSSL (libssl-dev)
#   win-x64    MSYS2's mingw-w64-x86_64-openssl package (/mingw64)
# The cross-compiled targets have no such OpenSSL on the build host, so each
# builds its own OpenSSL (shared) purely for its headers + import/symlink libs
# and points pjproject at it via --with-ssl=<prefix>. The native library is
# always linked dynamically and resolves libssl/libcrypto from the target
# system at runtime — nothing is bundled.
#
#   linux-arm64  cross-built on the Linux (docker) runner
#   win-x86      cross-built on the Linux runner (i686-w64-mingw32)
# ---------------------------------------------------------------------------
OPENSSL_VERSION ?= 3.6.4
OPENSSL_DIR    := $(abspath build/openssl)
OPENSSL_TAR    := $(OPENSSL_DIR)/openssl-$(OPENSSL_VERSION).tar.gz
OPENSSL_URL    := https://github.com/openssl/openssl/releases/download/openssl-$(OPENSSL_VERSION)/openssl-$(OPENSSL_VERSION).tar.gz

linux-arm64_SSL_PFX := $(OPENSSL_DIR)/prefix/linux-arm64
win-x86_SSL_PFX     := $(OPENSSL_DIR)/prefix/win-x86

# ---------------------------------------------------------------------------
# Target runtimes. For each RID we define:
#   <RID>_CONFIGURE_ARGS  pjproject ./configure arguments (--host=... when
#                         cross-compiling; empty = native host build)
#   <RID>_LIB             native library file name (libpjsua2.so / pjsua2.dll)
#   <RID>_LDFLAGS         extra link flags (optional)
#   <RID>_SSL_DEP         OpenSSL dev-file prerequisite (cross targets only)
# ---------------------------------------------------------------------------
RIDS ?= linux-x64 linux-arm64 win-x64 win-x86

linux-x64_CONFIGURE_ARGS   :=
linux-x64_LIB              := libpjsua2.so
linux-x64_LDFLAGS          :=
linux-x64_SSL_DEP          :=

linux-arm64_CONFIGURE_ARGS := --host=aarch64-linux-gnu --with-ssl=$(linux-arm64_SSL_PFX)
linux-arm64_LIB            := libpjsua2.so
linux-arm64_LDFLAGS        :=
linux-arm64_SSL_DEP        := $(linux-arm64_SSL_PFX)/lib/libssl.so.3

win-x64_CONFIGURE_ARGS     :=
win-x64_LIB                := pjsua2.dll
win-x64_LDFLAGS            := -static-libgcc -static-libstdc++ -lssl -lcrypto
win-x64_SSL_DEP            :=

win-x86_CONFIGURE_ARGS     := --host=i686-w64-mingw32 --with-ssl=$(win-x86_SSL_PFX)
win-x86_LIB                := pjsua2.dll
win-x86_LDFLAGS            := -static-libgcc -static-libstdc++
win-x86_SSL_DEP            := $(win-x86_SSL_PFX)/lib/libssl.dll.a

# pjproject source layout
SWIG_DIR     := $(PJDIR)/pjsip-apps/src/swig
SWIG_IFACE   := $(SWIG_DIR)/pjsua2.i
SWIG_INC     := -I$(PJDIR)/pjlib/include \
                -I$(PJDIR)/pjlib-util/include \
                -I$(PJDIR)/pjmedia/include \
                -I$(PJDIR)/pjsip/include \
                -I$(PJDIR)/pjnath/include -c++
CONFIG_SITE  := $(PJDIR)/pjlib/include/pj/config_site.h

# .NET project layout
DOTNET_PROJ  := pjsua2.net/codecrush.pjsua2.csproj
BINDINGS_DIR := pjsua2.net/bindings
NATIVE_DIR   := pjsua2.net/native
RUNTIME_BASE := pjsua2.net/runtimes
OUT_DIR      := artifacts

WRAP_CPP     := $(NATIVE_DIR)/pjsua2_wrap.cpp

# ---------------------------------------------------------------------------
# PJ_* variables (PJ_CXX, PJ_CXXFLAGS, PJ_LDXXFLAGS, PJ_LDXXLIBS) come from
# the generated build.mak, which only exists after ./configure has run for a
# given target. The per-RID recipes therefore re-enter make (see native-one /
# native-compile) so build.mak is current for the RID being built.
# ---------------------------------------------------------------------------
-include $(PJDIR)/build.mak

# --- OpenSSL cross-build -----------------------------------------------------

$(OPENSSL_TAR):
	@mkdir -p $(dir $@)
	curl -fL $(OPENSSL_URL) -o $@

$(linux-arm64_SSL_PFX)/lib/libssl.so.3: $(OPENSSL_TAR)
	@mkdir -p $(OPENSSL_DIR)/src-linux-arm64
	tar -xzf $(OPENSSL_TAR) -C $(OPENSSL_DIR)/src-linux-arm64
	cd $(OPENSSL_DIR)/src-linux-arm64/openssl-$(OPENSSL_VERSION) && \
	    ./Configure linux-aarch64 shared no-tests no-apps \
	        --prefix=$(linux-arm64_SSL_PFX) --cross-compile-prefix=aarch64-linux-gnu- && \
	    $(MAKE) -j$(JOBS) build_libs && $(MAKE) install_dev

# The 32-bit `mingw` target names its DLLs libssl-3.dll / libcrypto-3.dll (no
# suffix), the standard 32-bit OpenSSL-for-Windows names.
$(win-x86_SSL_PFX)/lib/libssl.dll.a: $(OPENSSL_TAR)
	@mkdir -p $(OPENSSL_DIR)/src-win-x86
	tar -xzf $(OPENSSL_TAR) -C $(OPENSSL_DIR)/src-win-x86
	cd $(OPENSSL_DIR)/src-win-x86/openssl-$(OPENSSL_VERSION) && \
	    ./Configure mingw shared no-tests no-apps \
	        --prefix=$(win-x86_SSL_PFX) --cross-compile-prefix=i686-w64-mingw32- && \
	    $(MAKE) -j$(JOBS) build_libs && $(MAKE) install_dev

.PHONY: all configure pjproject native native-one native-compile dotnet-build pack clean distclean

all: native dotnet-build

# --- SWIG bindings (generated once; identical for every RID) ---------------

# Modern config.guess reports the MSYS2/MINGW64 host as x86_64-pc-mingw64,
# which pjproject's aconfigure does not recognize as 64-bit (it only matches
# *_64-w64-mingw*), so PJ_WIN64 is left undefined and pj_sock_t falls back to
# a 4-byte long. On win-x64 that makes pj_fd_set_t too small to hold a winsock2
# fd_set, tripping the assert in sock_select.c. Define it here, guarded so the
# linux/win-x86 builds are unaffected.
#
# PJ_HAS_SSL_SOCK is forced to 1 because pjproject's ./configure only enables
# TLS when its OpenSSL detection succeeds, which is unreliable on the Windows
# runner (it treats the MSYS2 native build as a cross-compile and skips the
# OpenSSL probe, or fails to resolve the --with-ssl prefix path). Forcing it
# here guarantees the TLS code is compiled in for every RID; the OpenSSL
# symbols are satisfied by linking -lssl -lcrypto (see <RID>_LDFLAGS), and a
# missing OpenSSL then surfaces as a loud link error instead of a silently
# TLS-less DLL.
$(CONFIG_SITE):
	@printf '#if defined(_WIN64)\n#   define PJ_WIN64 1\n#endif\n#define PJ_HAS_SSL_SOCK 1\n' > $@

$(WRAP_CPP): $(SWIG_IFACE) $(CONFIG_SITE)
	@mkdir -p $(NATIVE_DIR) $(BINDINGS_DIR)
	swig $(SWIG_INC) -w312 -namespace $(NAMESPACE) -csharp \
	    -outdir $(BINDINGS_DIR) -o $@ $(SWIG_IFACE)

# --- Native libraries for every RID ----------------------------------------

native: $(WRAP_CPP)
	@for rid in $(RIDS); do \
		$(MAKE) --no-print-directory native-one RID=$$rid || exit 1; \
	done

# Configure + build pjproject for one RID, then compile/link the wrapper.
native-one: $($(RID)_SSL_DEP)
	@cross=$$(printf '%s' "$($(RID)_CONFIGURE_ARGS)" | sed -n 's/.*--host=\([^ ]*\).*/\1/p'); \
	if [ -n "$$cross" ] && ! command -v "$$cross-g++" >/dev/null 2>&1; then \
		echo "Error: cross compiler '$$cross-g++' not found (needed for $(RID))."; \
		exit 1; \
	fi
	@echo "==> Configuring pjproject for $(RID) ($($(RID)_CONFIGURE_ARGS))"
	cd $(PJDIR) && CFLAGS="-O2 -fPIC" CXXFLAGS="-g -O2 -fPIC" ./configure $($(RID)_CONFIGURE_ARGS)
	@echo "==> Building pjproject for $(RID)"
	$(MAKE) -C $(PJDIR) -j$(JOBS) lib
	@$(MAKE) --no-print-directory native-compile RID=$(RID)

# Re-entrant: build.mak is now current for this RID.
native-compile: $(RUNTIME_BASE)/$(RID)/native/$($(RID)_LIB)

$(RUNTIME_BASE)/$(RID)/native/$($(RID)_LIB): $(WRAP_CPP)
	@mkdir -p $(NATIVE_DIR)/$(RID) $(RUNTIME_BASE)/$(RID)/native
	$(PJ_CXX) -fPIC -c $(WRAP_CPP) -o $(NATIVE_DIR)/$(RID)/pjsua2_wrap.o $(PJ_CXXFLAGS)
	$(PJ_CXX) -shared -o $@ $(NATIVE_DIR)/$(RID)/pjsua2_wrap.o \
	    $(PJ_LDXXFLAGS) $(PJ_LDXXLIBS) $($(RID)_LDFLAGS)

# --- Host-only convenience targets (for local development) ------------------

configure:
	cd $(PJDIR) && CFLAGS="-O2 -fPIC" CXXFLAGS="-g -O2 -fPIC" ./configure

pjproject: configure
	$(MAKE) -C $(PJDIR) -j$(JOBS) lib

# --- Managed build + NuGet package -----------------------------------------

dotnet-build: native
	dotnet build $(DOTNET_PROJ) -c $(CONFIGURATION)

pack: dotnet-build
	dotnet pack $(DOTNET_PROJ) -c $(CONFIGURATION) -o $(OUT_DIR)

# --- Cleanup ---------------------------------------------------------------

clean:
	rm -rf $(BINDINGS_DIR) $(NATIVE_DIR) $(RUNTIME_BASE) $(OUT_DIR)
	rm -rf pjsua2.net/bin pjsua2.net/obj
	rm -f $(CONFIG_SITE)

distclean: clean
	$(MAKE) -C $(PJDIR) clean
	rm -rf build
	rm -f $(PJDIR)/build.mak
