# host-side bring-up test -- see README.md
#
#   make            static, self-contained, runs on any x86-64 Linux
#   make dynamic    smaller, but needs the local glibc
#   make check      says which kind you have
#
# STATIC IS THE DEFAULT ON PURPOSE. These binaries get copied to whichever PC
# is cabled to the board, and anything compiled on a modern Ubuntu wants
# __libc_start_main@GLIBC_2.34 -- glibc 2.34 folded libpthread into libc and
# gave that symbol a new version -- so a dynamic build will not start on an
# older release.
# Nothing in the source needs 2.34; it is purely where it was compiled.
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=c99 -pthread

all: uoe_loopback_test udp_echo

uoe_loopback_test: uoe_loopback_test.c
	$(CC) $(CFLAGS) -static -o $@ $<

udp_echo: udp_echo.c
	$(CC) $(CFLAGS) -static -o $@ $<

# only if you know the target's glibc is at least as new as this machine's
dynamic:
	$(CC) $(CFLAGS) -o uoe_loopback_test uoe_loopback_test.c
	$(CC) $(CFLAGS) -o udp_echo udp_echo.c

check:
	@for f in uoe_loopback_test udp_echo; do \
	  if ldd $$f 2>&1 | grep -q "not a dynamic executable"; then \
	    echo "  $$f: static, no glibc dependency"; \
	  else \
	    echo "  $$f: DYNAMIC -- needs $$(objdump -T $$f 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1)"; \
	  fi; \
	done

clean:
	rm -f uoe_loopback_test udp_echo

.PHONY: all dynamic check clean
