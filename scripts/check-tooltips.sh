#!/bin/bash
# Asserts that every settings row with an explanation actually has a system tooltip
# installed on it.
#
# Why this exists as its own gate: hovering cannot be automated on this machine
# (Accessibility is not granted, so synthesised mouse-moved events are dropped), and
# SwiftUI's `.help()` was found to install *nothing* — the app shipped 1.2 and 1.3 with
# every "?" badge silently inert. The app's `-dumpTooltips` diagnostic walks its own view
# tree and prints what AppKit actually holds.
#
# Two things are checked on every run, because either alone can lie:
#   * control=1  — a view with a known tooltip IS found, so a count of 0 means "absent",
#                  not "the walker is blind". Without this the whole gate passes vacuously.
#   * the exact number of tooltip-bearing views per tab, and 0 with the pane closed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

CONFIG="${CONFIG:-debug}"
swift build -c "${CONFIG}" >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build -c "${CONFIG}" --show-bin-path)/SevenZipCompressorApp"
test -x "${BIN}" || { echo "app binary not found: ${BIN}" >&2; exit 1; }

failures=0

# macOS has no `timeout`, and the app is expected to quit itself from the diagnostic. If
# it cannot (no window server, a stall), the command substitution would block forever and
# take `make tips` and the tooltip mutations with it.
run_app() {                   # run_app <args...>
  local out_file; out_file="$(mktemp)"
  "${BIN}" "$@" >"${out_file}" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "${pid}" 2>/dev/null; do
    sleep 0.5
    waited=$((waited + 1))
    if [ "${waited}" -gt 40 ]; then      # 20s; the diagnostic fires at 2.5s
      kill -9 "${pid}" 2>/dev/null
      echo "TIMEOUT"
      rm -f "${out_file}"
      return
    fi
  done
  cat "${out_file}"
  rm -f "${out_file}"
}

# The counts below are only stable if the app starts from its default settings: a
# persisted fixed destination adds a tooltip (the path line) and a persisted
# passwordMode=shared adds the 共通パスワード row. A bare executable keeps its own
# persistent defaults domain across runs, so anyone who launches it by hand and changes a
# setting would otherwise poison this gate. Passing non-Data values for the three settings
# keys on the argument domain — which outranks the persistent one — makes
# `UserDefaults.data(forKey:)` return nil for each, so the app falls back to its defaults.
CLEAN_STATE=(-appSettingsV2 reset -appSettings reset -compressionSettings reset)

# One tooltip per row that passes a `help:` string. Update these when rows are added or
# removed — a changed count must be a deliberate edit, not a silent loss.
check() {                     # check <tab> <settingsOpen> <expected>
  local tab="$1" open="$2" expected="$3" out count control
  out="$(run_app -dumpTooltips 1 -isSettingsOpen "${open}" -settingsTab "${tab}" "${CLEAN_STATE[@]}")"
  if [ "${out}" = "TIMEOUT" ]; then
    echo "  FAIL  ${tab} (open=${open}): the app did not finish the dump within 20s"
    failures=$((failures + 1))
    return
  fi
  count="$(printf '%s\n' "${out}" | sed -n 's/.*tooltipViews=\([0-9]*\).*/\1/p' | tail -1)"
  control="$(printf '%s\n' "${out}" | sed -n 's/.*control=\([0-9]*\).*/\1/p' | tail -1)"

  if [ "${control:-0}" != "1" ]; then
    echo "  FAIL  ${tab} (open=${open}): the walker did not find its own control tooltip"
    echo "        => a count of ${count:-?} proves nothing; fix the diagnostic first"
    failures=$((failures + 1))
    return
  fi
  if [ -z "${count}" ]; then
    echo "  FAIL  ${tab} (open=${open}): no tooltipViews line in the output"
    failures=$((failures + 1))
    return
  fi
  if [ "${count}" != "${expected}" ]; then
    echo "  FAIL  ${tab} (open=${open}): ${count} tooltip views, expected ${expected}"
    failures=$((failures + 1))
    return
  fi
  echo "  ok    ${tab} (open=${open}): ${count} rows explain themselves"
}

echo "system tooltips installed on the settings rows:"
check general  1 13
check sevenZip 1 4
check zip      1 3
check general  0 0     # pane closed: the rows are not built, so nothing is installed

# The tooltip must cover the whole row, not just the 11pt "?" glyph: a row is about 46pt
# tall and ~370pt wide in the 408pt pane.
echo
echo "the tooltip covers the row, not just the badge:"
geometry="$(run_app -dumpTooltips 1 -isSettingsOpen 1 -settingsTab general "${CLEAN_STATE[@]}" \
            | sed -n 's/^TIP .* \([0-9]*\)x\([0-9]*\) text=.*/\1 \2/p')"
narrow="$(printf '%s\n' "${geometry}" | awk '$1 < 200 || $2 < 30' | wc -l | tr -d ' ')"
total="$(printf '%s\n' "${geometry}" | grep -c . || true)"
if [ "${total}" -eq 0 ]; then
  echo "  FAIL  no TIP lines to measure"
  failures=$((failures + 1))
elif [ "${narrow}" -ne 0 ]; then
  echo "  FAIL  ${narrow}/${total} tooltip views are smaller than a row"
  failures=$((failures + 1))
else
  echo "  ok    all ${total} tooltip views are row-sized"
fi

echo
if [ "${failures}" -ne 0 ]; then
  echo "${failures} tooltip check(s) failed" >&2
  exit 1
fi
echo "all tooltip checks passed"
