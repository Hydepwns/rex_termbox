# Default Mix app path if not provided (e.g., when running make directly)
MIX_APP_PATH ?= _build/dev/lib/rrex_termbox

PREFIX = $(MIX_APP_PATH)/priv
BUILD  = $(MIX_APP_PATH)/obj

TERMBOX_PATH = c_src/termbox
TERMBOX_BUILD = $(MIX_APP_PATH)/termbox_build
TERMBOX_LIB_INSTALL_PATH = $(TERMBOX_PATH)/lib/libtermbox.a # Actual install location

# Executable name
PORT_EXECUTABLE = termbox_port
PORT_TARGET = $(PREFIX)/$(PORT_EXECUTABLE)

# C Compiler and Flags for Port executable
# Using MIX_ARCH and MIX_TARGET for potential cross-compilation awareness
CC ?= gcc # Use system default or mix specified CC, defaulting to gcc
CFLAGS = -std=c99 -O2 -Wall -Wextra -g # Example flags, adjust as needed
# Remove platform-specific shared library flags
# Add include path for termbox library headers
CFLAGS += -I$(TERMBOX_PATH)/src
# LDFLAGS are typically not needed for basic executable linking unless specific libs are required
LDFLAGS = -lncurses # Link against ncurses

# Keep NIF flags commented out for reference or future use, but not used for port
# NIF_CFLAGS = -I$(ERTS_INCLUDE_DIR) -I$(TERMBOX_PATH)/src

# Source file for the port executable
PORT_SOURCE = c_src/termbox_port.c

# Default target is now the port executable
all: $(PORT_TARGET)
	@:

# Rule to build and install the termbox static library
$(TERMBOX_LIB_INSTALL_PATH): $(TERMBOX_BUILD)
	@echo "--- Building libtermbox.a ---"
	rm -f $(TERMBOX_LIB_INSTALL_PATH)
	# Ensure Waf commands run in the correct directory and inherit environment
	cd $(TERMBOX_PATH) && export CFLAGS="-O2 -g -fPIC" && export ARCHFLAGS="-arch $(shell uname -m)" && export LDFLAGS="" && ./waf configure --prefix=. -o $(TERMBOX_BUILD) -v && ./waf build -v && ./waf install -v

# Rule to build the port executable
$(PORT_TARGET): $(PORT_SOURCE) $(TERMBOX_LIB_INSTALL_PATH) $(PREFIX)
	@echo "--- Building $(PORT_EXECUTABLE) ---"
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(PORT_SOURCE) $(TERMBOX_LIB_INSTALL_PATH)

$(PREFIX) $(TERMBOX_BUILD):
	@echo "--- Creating directory $@ ---"
	mkdir -p $@

clean:
	@echo "--- Cleaning build artifacts ---"
	rm -rf $(TERMBOX_BUILD) $(PORT_TARGET)

.PHONY: all clean
# Remove calling_from_make if not needed or update it
# calling_from_make:
#	mix compile
