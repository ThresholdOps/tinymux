#!/bin/bash
#
#   run_wedge.sh — #2238 stubslave-wedge regression.
#
#   A synchronous stubslave COM call parks the WHOLE server inside
#   GanlAdapter::pump_stubslave.  That pump used to poll(fd, -1) — a
#   single-fd, infinite-timeout wait — so a channel that went quiet took
#   the server with it: no network events, no timers, no dumps, no signal
#   processing, not even @shutdown.  A farm deployment sat wedged, silent
#   and at zero CPU, for 22 days before anyone noticed.  do_dbck drives one
#   of these round-trips every check_interval, so it is not a rare path.
#
#   This reproduces the wedge deterministically with SIGSTOP: the stubslave
#   stays alive and keeps its end of the socketpair open (so there is no
#   EOF and no HUP to rescue the poll) but never reads or replies — exactly
#   the shape of the captured hang.  We then drive a COM round-trip through
#   @dbck, which is the very command the farm hang was attributed to.
#
#   Pre-fix: muxscript hangs forever and the harness times out.
#   Post-fix: the pump gives up after TINYMUX_STUB_STALL_MS, logs
#   NET/STUB, tears the channel down, and the game keeps running — so
#   @shutdown is still honoured and we exit 0.
#
#   SKIP (green) without muxscript or on a build with no stubslave, same
#   policy as tests/stubslave.
#
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
BIN="$REPO_ROOT/mux/game/bin"
WORK="$SCRIPT_DIR/work"

# The wedge must resolve well inside the harness timeout, or a PASS would
# just mean "the timeout was generous".
STALL_MS=4000
if command -v timeout >/dev/null 2>&1; then
    TO="timeout 40"
elif command -v gtimeout >/dev/null 2>&1; then
    TO="gtimeout 40"
else
    TO=""
fi

if [ ! -x "$BIN/muxscript" ]; then
    echo "SKIP: $BIN/muxscript not found (run 'make install' first)."
    exit 0
fi
if [ ! -x "$BIN/stubslave" ]; then
    echo "SKIP: $BIN/stubslave not built (configure --enable-stubslave)."
    exit 0
fi

rm -rf "$WORK"; mkdir -p "$WORK/data"
( cd "$WORK" || exit 1
  ln -s "$BIN" bin
  cp "$REPO_ROOT/mux/game/alias.conf" "$REPO_ROOT/mux/game/compat.conf" . 2>/dev/null
  cat > p.conf <<PCONF
input_database  data/p.db
output_database data/p.db.new
crash_database  data/p.db.CRASH
mail_database   data/mail.db
comsys_database data/comsys.db
port 0
mud_name StubWedge
include alias.conf
include compat.conf
PCONF
)

cd "$WORK" || exit 1
ulimit -c 0 2>/dev/null || true
FIFO="in.fifo"; rm -f "$FIFO"; mkfifo "$FIFO"

LD_LIBRARY_PATH="$BIN" TINYMUX_STUB_STALL_MS="$STALL_MS" \
    $TO "$BIN/muxscript" -g . -c p.conf < "$FIFO" > out.log 2> err.log &
mpid=$!
exec 3>"$FIFO"

echo 'think READY|ok' >&3

slave=""
for i in $(seq 1 80); do
    slave=$(grep -oE 'stubslave attached \(pid [0-9]+\)' err.log 2>/dev/null \
            | grep -oE '[0-9]+' | head -1)
    [ -n "$slave" ] && break
    kill -0 "$mpid" 2>/dev/null || break
    sleep 0.1
done

if [ -z "$slave" ]; then
    echo "SKIP: muxscript did not attach a stubslave (in-proc-only build/run)."
    echo '@shutdown' >&3 2>/dev/null || true
    exec 3>&-
    wait "$mpid" 2>/dev/null
    exit 0
fi
echo "   stubslave pid=$slave"

# Wedge it: alive, socket open, but it will never read or reply.
kill -STOP "$slave" 2>/dev/null
sleep 0.3

# Drive a synchronous COM round-trip into the wedged channel.  This is the
# call that hung the farm.
echo '@dbck' >&3
echo 'think AFTERWEDGE|still-alive' >&3
echo '@shutdown' >&3
exec 3>&-

wait "$mpid"; rc=$?
kill -CONT "$slave" 2>/dev/null
kill -9 "$slave" 2>/dev/null

fail=0
echo "   exit rc=$rc"
case "$rc" in
    0)   echo "   PASS: server survived the wedged channel and shut down cleanly" ;;
    124) echo "   FAIL: hung on the wedged stubslave (the #2238 infinite poll is back)"; fail=1 ;;
    *)   echo "   FAIL: unexpected exit rc=$rc"; fail=1 ;;
esac

if grep -qi "stubslave channel stalled" err.log out.log 2>/dev/null; then
    echo "   PASS: stall was detected and logged (NET/STUB)"
else
    echo "   FAIL: no stall diagnostic logged — recovery, if any, was silent"
    fail=1
fi

if grep -q "AFTERWEDGE|still-alive" out.log 2>/dev/null; then
    echo "   PASS: command processing continued after the channel was dropped"
else
    echo "   FAIL: no command output after the wedge — the game did not continue"
    fail=1
fi

exit $fail
