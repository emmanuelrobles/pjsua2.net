# pjsua2.net — build pjsua2 and the SWIG C# bindings, then pack a NuGet package.
#
# This Makefile drives the full pipeline:
#   1. configure + build the pjproject submodule (with -fPIC so we can link a .so)
#   2. run SWIG to generate the C# bindings + native wrapper (pjsua2_wrap.cpp)
#   3. compile the wrapper and link libpjsua2.so (linux-x64)
#   4. dotnet build / pack the pjsua2.net project into a NuGet package
#
# Targets:
#   all            build native library + managed assembly (default)
#   pack           build everything and produce the .nupkg in $(OUT_DIR)
#   configure      run pjproject's ./configure (idempotent)
#   pjproject      build the pjproject static libraries
#   native         generate bindings + libpjsua2.so
#   dotnet-build   dotnet build the managed project
#   clean          remove generated bindings/native/nuget artifacts
#   distclean      clean + fully clean the pjproject tree
#
# Overridable:
#   CONFIGURATION  dotnet build configuration (default: Release)
#   JOBS           number of parallel pjproject build jobs (default: nproc)
#   NAMESPACE      C# namespace for the bindings (default: pjsua2)

PJDIR        := pjproject
MAKE         ?= make
JOBS         ?= $(shell nproc 2>/dev/null || echo 4)
CONFIGURATION ?= Release
NAMESPACE    ?= pjsua2

# pjproject source layout
SWIG_DIR     := $(PJDIR)/pjsip-apps/src/swig
SWIG_IFACE   := $(SWIG_DIR)/pjsua2.i
SWIG_INC     := -I$(PJDIR)/pjlib/include \
                -I$(PJDIR)/pjlib-util/include \
                -I$(PJDIR)/pjmedia/include \
                -I$(PJDIR)/pjsip/include \
                -I$(PJDIR)/pjnath/include -c++

# .NET project layout
DOTNET_PROJ  := pjsua2.net/pjsua2.net.csproj
BINDINGS_DIR := pjsua2.net/bindings
NATIVE_DIR   := pjsua2.net/native
RUNTIME_DIR  := pjsua2.net/runtimes/linux-x64/native
NATIVE_LIB   := $(RUNTIME_DIR)/libpjsua2.so
OUT_DIR      := artifacts

WRAP_CPP     := $(NATIVE_DIR)/pjsua2_wrap.cpp
WRAP_OBJ     := $(NATIVE_DIR)/pjsua2_wrap.o

# ---------------------------------------------------------------------------
# PJ_* variables (PJ_CXX, PJ_CXXFLAGS, PJ_LDXXFLAGS, PJ_LDXXLIBS) are defined
# by the generated build.mak. It does not exist until `make configure` has run,
# so the native recipes are reached through a re-entrant make (see `native`).
# ---------------------------------------------------------------------------
-include $(PJDIR)/build.mak

.PHONY: all configure pjproject native native-only dotnet-build pack clean distclean

all: native dotnet-build

# --- Phase 1: pjproject ----------------------------------------------------

# (Re)generate pjproject/build.mak. -fPIC is required to link libpjsua2.so.
$(PJDIR)/build.mak: $(PJDIR)/aconfigure
	cd $(PJDIR) && CFLAGS="-O2 -fPIC" CXXFLAGS="-g -O2 -fPIC" ./configure

configure: $(PJDIR)/build.mak

pjproject: configure
	$(MAKE) -C $(PJDIR) -j$(JOBS)

# --- Phase 2: SWIG bindings + native library ------------------------------
# Re-invoke make now that pjproject/build.mak exists, so the PJ_* variables
# are defined for the native recipes below.

native: pjproject
	$(MAKE) --no-print-directory native-only

native-only: $(NATIVE_LIB)

$(WRAP_CPP): $(SWIG_IFACE) $(PJDIR)/build.mak
	@mkdir -p $(NATIVE_DIR) $(BINDINGS_DIR)
	swig $(SWIG_INC) -w312 -namespace $(NAMESPACE) -csharp \
	    -outdir $(BINDINGS_DIR) -o $@ $(SWIG_IFACE)

$(WRAP_OBJ): $(WRAP_CPP)
	$(PJ_CXX) -fPIC -c $< -o $@ $(PJ_CXXFLAGS)

$(NATIVE_LIB): $(WRAP_OBJ)
	@mkdir -p $(RUNTIME_DIR)
	$(PJ_CXX) -shared -o $@ $< $(PJ_LDXXFLAGS) $(PJ_LDXXLIBS)

# --- Managed build + NuGet package -----------------------------------------

dotnet-build: native
	dotnet build $(DOTNET_PROJ) -c $(CONFIGURATION)

pack: dotnet-build
	dotnet pack $(DOTNET_PROJ) -c $(CONFIGURATION) -o $(OUT_DIR)

# --- Cleanup ---------------------------------------------------------------

clean:
	rm -rf $(BINDINGS_DIR) $(NATIVE_DIR) $(RUNTIME_DIR) $(OUT_DIR)
	rm -rf pjsua2.net/bin pjsua2.net/obj

distclean: clean
	$(MAKE) -C $(PJDIR) clean
	rm -f $(PJDIR)/build.mak
