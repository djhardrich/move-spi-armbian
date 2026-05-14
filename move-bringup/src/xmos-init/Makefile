# Build the move-xmos-init replay tool. Run from debian/rules.
CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra
LDFLAGS ?=

PREFIX     ?= /usr
SBIN_DIR   ?= $(PREFIX)/sbin

BIN = move-xmos-init
SRC = move-xmos-init.c

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) $(CPPFLAGS) $(LDFLAGS) -o $@ $<

install: $(BIN)
	install -d $(DESTDIR)$(SBIN_DIR)
	install -m 0755 $(BIN) $(DESTDIR)$(SBIN_DIR)/$(BIN)

clean:
	rm -f $(BIN)

.PHONY: all install clean
