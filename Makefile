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
# NIF_SOURCE = c_src/termbox_bindings.c
# NIF_OBJECT_NAME = termbox_bindings
# Determine OS for shared library extension
# UNAME_S := $(shell uname -s)
# ifeq ($(UNAME_S),Linux)
# 	NIF_EXT = .so
# else ifeq ($(UNAME_S),Darwin)
# 	NIF_EXT = .so # Use .so for macOS too, as erlang expects it for NIFs
# else
# 	NIF_EXT = .so # Default
# endif
# NIF_TARGET = $(PREFIX)/$(NIF_OBJECT_NAME)$(NIF_EXT)

# C Compiler and Flags
CC ?= gcc # Use system default or mix specified CC, defaulting to gcc
CFLAGS_BASE = -std=c99 -O2 -Wall -Wextra -g # Common flags
LDFLAGS_BASE = # Common linker flags (if any)

# Add conditional flag for test environment
ifeq ($(MIX_ENV),test)
	TEST_FLAGS = -DTESTING_WITHOUT_TERMBOX
else
	TEST_FLAGS = 
endif

# Flags for Port executable
CFLAGS_PORT = $(CFLAGS_BASE) -I$(TERMBOX_PATH)/src $(TEST_FLAGS)
LDFLAGS_PORT = $(LDFLAGS_BASE) -lncurses

# Flags for NIF shared library
# Add -fPIC for position-independent code
# Add Erlang include paths (assuming compiler finds erl_nif.h)
# ERLANG_INCLUDE_PATH = /opt/homebrew/Cellar/erlang/27.3.2/lib/erlang/usr/include
# CFLAGS_NIF = $(CFLAGS_BASE) -fPIC -I$(ERLANG_INCLUDE_PATH) -I$(TERMBOX_PATH)/src
# Link as shared library, link termbox static lib
# LDFLAGS_NIF = $(LDFLAGS_BASE) -shared -undefined dynamic_lookup

# Use consistent path for linking, assuming dev build exists when testing
TERMBOX_LINK_PATH = $(MIX_APP_PATH)/termbox_build/lib/libtermbox.a 

# Conditional dependency: Only depend on termbox build rule if not testing
ifeq ($(MIX_ENV),test)
	TERMBOX_DEPENDENCY = 
	TERMBOX_LINK_INPUT_PORT = 
	# TERMBOX_LINK_INPUT_NIF = $(TERMBOX_LINK_PATH) # NIF REMOVED
else
	TERMBOX_DEPENDENCY = $(TERMBOX_LIB_INSTALL_PATH)
	TERMBOX_LINK_INPUT_PORT = $(TERMBOX_LINK_PATH)
	# TERMBOX_LINK_INPUT_NIF = $(TERMBOX_LINK_PATH) # NIF REMOVED
endif

# Default target builds the port executable
all: $(PORT_TARGET)
	@:

# Rule to build and install the termbox static library
# Ensure waf build happens first by making it a prerequisite for targets needing it
# --> ONLY BUILD IF NOT IN TEST ENV <--
ifneq ($(MIX_ENV),test)
$(TERMBOX_LIB_INSTALL_PATH): $(TERMBOX_BUILD)
	@echo "--- Building libtermbox.a ---"
	# Waf install should place the library at $(TERMBOX_BUILD)/lib/libtermbox.a
	cd $(TERMBOX_PATH) && export CFLAGS="-O2 -g -fPIC" && export ARCHFLAGS="-arch $(shell uname -m)" && export LDFLAGS="" && ./waf configure --prefix=$(TERMBOX_BUILD) -o $(TERMBOX_BUILD)/build -v && ./waf build -v && ./waf install -v
endif

# Rule to build the port executable
# Links against TERMBOX_LINK_PATH. Requires TERMBOX_LIB_INSTALL_PATH rule ran (in dev) or file exists.
$(PORT_TARGET): $(PORT_SOURCE) $(PREFIX) $(TERMBOX_DEPENDENCY)
	@echo "--- Building $(PORT_EXECUTABLE) (MIX_ENV=$(MIX_ENV)) ---"
	$(CC) $(CFLAGS_PORT) $(LDFLAGS_PORT) -o $@ $(PORT_SOURCE) $(TERMBOX_LINK_INPUT_PORT)

# Rule to build the NIF shared library -- (REMOVED) -- #
# $(NIF_TARGET): $(NIF_SOURCE) $(PREFIX) $(TERMBOX_DEPENDENCY)
# 	@echo "--- Building $(NIF_OBJECT_NAME)$(NIF_EXT) (MIX_ENV=$(MIX_ENV)) ---"
# 	$(CC) $(CFLAGS_NIF) $(LDFLAGS_NIF) -o $@ $(NIF_SOURCE) $(TERMBOX_LINK_INPUT_NIF)

$(PREFIX) $(TERMBOX_BUILD):
	@echo "--- Creating directory $@ ---"
	mkdir -p $@

clean:
	@echo "--- Cleaning build artifacts ---"
# --> ONLY CLEAN TERMBOX BUILD IF NOT IN TEST ENV <--
ifneq ($(MIX_ENV),test)
	rm -rf $(TERMBOX_BUILD)
endif
	rm -f $(PORT_TARGET) # Removed NIF_TARGET

.PHONY: all clean
