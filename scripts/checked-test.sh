#!/usr/bin/env bash
# Runs a test command for `make test`, keeps its output in LOG, and fails when
# the command fails, when any test was skipped (a skipped test is not a passing
# test), when no Swift Testing summary says the run passed, or when the device
# benchmark or the UI flows ran: those belong to their own schemes only. The
# same checks as scripts/verify-phase3b.sh makes.
#
#   bash scripts/checked-test.sh LOG COMMAND...
set -u

log=${1:?usage: bash scripts/checked-test.sh LOG COMMAND...}
shift
mkdir -p "$(dirname "$log")"
"$@" 2>&1 | tee "$log"
# tee's status would hide the tests'.
code=${PIPESTATUS[0]}

# appintentsmetadataprocessor reports its own "Metadata extraction skipped"
# for every app without App Intents; that is not a test.
if grep -iE 'skipped' "$log" | grep -qv 'appintentsmetadataprocessor'; then
  echo "TEST CHECK: skipped tests found in $log" >&2
  code=1
fi
if ! grep -qE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$log"; then
  echo "TEST CHECK: no passing Swift Testing summary line in $log" >&2
  code=1
fi
if grep -qE 'BuildBenchmark|FlowTests' "$log"; then
  echo "TEST CHECK: the benchmark or the UI flows ran in a normal test run ($log)" >&2
  code=1
fi
exit $code
