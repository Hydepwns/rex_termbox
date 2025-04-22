PREFIX = $(MIX_APP_PATH)/priv
BUILD  = $(MIX_APP_PATH)/obj

TERMBOX_PATH = c_src/termbox
TERMBOX_BUILD = $(MIX_APP_PATH)/termbox_build

ifeq ($(CROSSCOMPILE),)
    # Normal build. Set shared library flags according to the platform.
    ifeq ($(shell uname),Darwin)
	LDFLAGS += -dynamiclib -undefined dynamic_lookup
        CFLAGS += -arch arm64 # Explicitly set arch for Apple Silicon
        LDFLAGS += -arch arm64 # Explicitly set arch for Apple Silicon
    endif
    ifeq ($(shell uname -s),Linux)
        LDFLAGS += -fPIC -shared
        CFLAGS += -fPIC
        CFLAGS += -g
    endif
else
    # Crosscompiled build. Assume Linux flags
    LDFLAGS += -fPIC -shared
    CFLAGS += -fPIC
    CFLAGS += -g
endif

NIF_CFLAGS += -I$(ERTS_INCLUDE_DIR) -I$(TERMBOX_PATH)/src

SOURCES = c_src/termbox_bindings.c $(TERMBOX_BUILD)/src/libtermbox.a

calling_from_make:
	mix compile

all: $(PREFIX)/termbox_bindings.so
	@:

$(TERMBOX_BUILD)/src/libtermbox.%: $(TERMBOX_BUILD)
	cd $(TERMBOX_PATH) && ARCHFLAGS="-arch $(shell uname -m)" CFLAGS="$(CFLAGS)" LDFLAGS="$(LDFLAGS)" ./waf configure --prefix=. -o $(TERMBOX_BUILD) && ./waf build install

$(PREFIX)/termbox_bindings.so: $(SOURCES) $(PREFIX)
	$(CC) $(CFLAGS) $(NIF_CFLAGS) $(LDFLAGS) -o $@ $(SOURCES)

$(PREFIX) $(TERMBOX_BUILD):
	mkdir -p $@

clean:
	rm -rf $(TERMBOX_BUILD) $(PREFIX)/termbox_bindings.so

.PHONY: calling_from_make all clean
