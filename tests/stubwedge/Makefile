# tests/stubwedge — #2238 stubslave-wedge regression.
#
# Needs a built muxscript + stubslave (make install from the repo root with
# configure --enable-stubslave).  Skips green on builds without stubslave.

.PHONY: all test clean

all:
	@true

test:
	@bash ./run_wedge.sh

clean:
	@rm -rf work
