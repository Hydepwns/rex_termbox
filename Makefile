# Default Mix app path if not provided (e.g., when running make directly)
MIX_APP_PATH ?= _build/dev/lib/rrex_termbox

PREFIX = $(MIX_APP_PATH)/priv
BUILD  = $(MIX_APP_PATH)/obj

# --- Termbox Static Lib --- #
TERMBOX_PATH = c_src/termbox
TERMBOX_BUILD = $(MIX_APP_PATH)/termbox_build
TERMBOX_LIB_INSTALL_PATH = $(TERMBOX_BUILD)/lib/libtermbox.a # Changed from termbox/lib to termbox_build/lib

# --- Port Executable --- #
PORT_EXECUTABLE = termbox_port
PORT_SOURCE = c_src/termbox_port.c
PORT_TARGET = $(PREFIX)/$(PORT_EXECUTABLE)

# --- NIF Shared Library --- #
NIF_SOURCE = c_src/termbox_bindings.c
NIF_OBJECT_NAME = termbox_bindings
# Determine OS for shared library extension
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
	NIF_EXT = .so
else ifeq ($(UNAME_S),Darwin)
	NIF_EXT = .so # Use .so for macOS too, as erlang expects it for NIFs
else
	NIF_EXT = .so # Default
endif
NIF_TARGET = $(PREFIX)/$(NIF_OBJECT_NAME)$(NIF_EXT)

# C Compiler and Flags
CC ?= gcc # Use system default or mix specified CC, defaulting to gcc
CFLAGS_BASE = -std=c99 -O2 -Wall -Wextra -g # Common flags
LDFLAGS_BASE = # Common linker flags (if any)

# Flags for Port executable
CFLAGS_PORT = $(CFLAGS_BASE) -I$(TERMBOX_PATH)/src
LDFLAGS_PORT = $(LDFLAGS_BASE) -lncurses

# Flags for NIF shared library
# Add -fPIC for position-independent code
# Add Erlang include paths (assuming compiler finds erl_nif.h)
ERLANG_INCLUDE_PATH = /opt/homebrew/Cellar/erlang/27.3.2/lib/erlang/usr/include
CFLAGS_NIF = $(CFLAGS_BASE) -fPIC -I$(ERLANG_INCLUDE_PATH) -I$(TERMBOX_PATH)/src
# Link as shared library, link termbox static lib
LDFLAGS_NIF = $(LDFLAGS_BASE) -shared -undefined dynamic_lookup


# Default target builds both port and NIF
all: $(PORT_TARGET) $(NIF_TARGET)
	@:

# Rule to build and install the termbox static library
# Ensure waf build happens first by making it a prerequisite for targets needing it
$(TERMBOX_LIB_INSTALL_PATH): $(TERMBOX_BUILD)
	@echo "--- Building libtermbox.a ---"
	# Waf install should place the library at $(TERMBOX_BUILD)/lib/libtermbox.a
	cd $(TERMBOX_PATH) && export CFLAGS="-O2 -g -fPIC" && export ARCHFLAGS="-arch $(shell uname -m)" && export LDFLAGS="" && ./waf configure --prefix=$(TERMBOX_BUILD) -o $(TERMBOX_BUILD)/build -v && ./waf build -v && ./waf install -v

# Rule to build the port executable
# Depends on the termbox library being built and installed by waf
$(PORT_TARGET): $(PORT_SOURCE) $(TERMBOX_LIB_INSTALL_PATH) $(PREFIX)
	@echo "--- Building $(PORT_EXECUTABLE) ---"
	$(CC) $(CFLAGS_PORT) $(LDFLAGS_PORT) -o $@ $(PORT_SOURCE) $(TERMBOX_LIB_INSTALL_PATH)

# Rule to build the NIF shared library
# Depends on the termbox library being built and installed by waf
$(NIF_TARGET): $(NIF_SOURCE) $(TERMBOX_LIB_INSTALL_PATH) $(PREFIX)
	@echo "--- Building $(NIF_OBJECT_NAME)$(NIF_EXT) ---"
	$(CC) $(CFLAGS_NIF) $(LDFLAGS_NIF) -o $@ $(NIF_SOURCE) $(TERMBOX_LIB_INSTALL_PATH)

$(PREFIX) $(TERMBOX_BUILD):
	@echo "--- Creating directory $@ ---"
	mkdir -p $@

clean:
	@echo "--- Cleaning build artifacts ---"
	rm -rf $(TERMBOX_BUILD) $(PORT_TARGET) $(NIF_TARGET)

.PHONY: all clean
