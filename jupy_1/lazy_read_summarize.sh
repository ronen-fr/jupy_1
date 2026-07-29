#!/bin/bash
# lazy_read_summarize.sh
#
# Re-run the summary/comparison logic on existing dump files.
#
# Usage:
#   bash ~/src/lazy_read_summarize.sh pdump_28_1356
#
# Expects these files in /tmp:
#   ${base}_osd*_N0.json   (disabled, before)
#   ${base}_osd*_N1.json   (disabled, after)
#   ${base}_osd*_Y0.json   (enabled, before)
#   ${base}_osd*_Y1.json   (enabled, after)
#
# Or the old single-OSD format (no _osdN_ infix):
#   ${base}_N0, ${base}_N1, ${base}_Y0, ${base}_Y1

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <base_name>  (e.g. pdump_28_1356)"
  exit 1
fi

base=$1
JQ_SUMMARIZE=~/src/summarize_lazy_read_metrics.jq
short_fname="/tmp/${base}_final.txt"

# ── locate dump files ─────────────────────────────────────────────

find_phase_files() {
  local phase=$1
  local files=()
  # multi-OSD format: ${base}_osd*_${phase}.json
  mapfile -t files < <(ls /tmp/${base}_osd*_${phase}.json 2>/dev/null | sort -V)
  if [[ ${#files[@]} -eq 0 ]]; then
    # single-OSD format: ${base}_${phase} (no .json suffix)
    if [[ -f "/tmp/${base}_${phase}" ]]; then
      files=("/tmp/${base}_${phase}")
    fi
  fi
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "ERROR: no files found for phase ${phase} (tried /tmp/${base}_osd*_${phase}.json and /tmp/${base}_${phase})" >&2
    exit 1
  fi
  printf '%s\n' "${files[@]}"
}

summarize_files() {
  local files=("$@")
  for f in "${files[@]}"; do
    sed -n '/^{/,$p' "$f"
  done | jq -s '{metrics: [.[].metrics[]]}' | jq -f "$JQ_SUMMARIZE"
}

compute_delta() {
  local before=$1 after=$2
  jq -n --argjson before "$before" --argjson after "$after" '
  def safe_div(n; d): if d > 0 then (n / d * 10000 | round / 10000) else 0 end;

  ($after.read_transactions.created    - $before.read_transactions.created) as $d_created |
  ($after.read_transactions.successful - $before.read_transactions.successful) as $d_successful |
  ($after.read_invalidations.total     - $before.read_invalidations.total) as $d_inval |
  ($after.lazy_read.skipped_registrations - $before.lazy_read.skipped_registrations) as $d_skipped |
  ($after.lazy_read.stale_retries         - $before.lazy_read.stale_retries) as $d_retries |
  ($after.lazy_read.cursor_refreshes      - $before.lazy_read.cursor_refreshes) as $d_refreshes |
  ($after.read_latency.total_ops - $before.read_latency.total_ops) as $d_ops |
  ($after.read_latency.total_ms  - $before.read_latency.total_ms)  as $d_lat_ms |
  ($after.conflict_replays.total_transactions - $before.conflict_replays.total_transactions) as $d_replay_txns |
  ($after.conflict_replays.total_replays      - $before.conflict_replays.total_replays) as $d_replays |

  (if ($after.read_latency.histogram | length) > 0
       and ($before.read_latency.histogram | length) > 0
   then [ range($after.read_latency.histogram | length) | . as $i |
          { le:    $after.read_latency.histogram[$i].le,
            count: ($after.read_latency.histogram[$i].count -
                    $before.read_latency.histogram[$i].count) } ]
   else [] end) as $d_hist |

  {
    read_transactions: {
      created:               $d_created,
      successful:            $d_successful,
      invalidation_rate_pct: (if $d_created > 0
                              then (100 * (1 - ($d_successful / $d_created))
                                    | . * 10000 | round / 10000)
                              else 0 end)
    },
    read_invalidations:      { total: $d_inval },
    lazy_read: {
      skipped_registrations: $d_skipped,
      stale_retries:         $d_retries,
      cursor_refreshes:      $d_refreshes,
      net_benefit:           ($d_skipped - $d_retries)
    },
    read_latency: {
      total_ops:  $d_ops,
      total_ms:   ($d_lat_ms * 10000 | round / 10000),
      avg_ms:     safe_div($d_lat_ms; $d_ops),
      histogram:  $d_hist
    },
    conflict_replays: {
      total_transactions:  $d_replay_txns,
      total_replays:       $d_replays,
      avg_replays_per_txn: safe_div($d_replays; $d_replay_txns)
    }
  }'
}

write_section() {
  local header=$1 json=$2
  echo "" >> "$short_fname"
  echo "=== $header ===" >> "$short_fname"
  echo "$json" >> "$short_fname"
}

# ── find files for each phase ─────────────────────────────────────

mapfile -t n0_files < <(find_phase_files N0)
mapfile -t n1_files < <(find_phase_files N1)
mapfile -t y0_files < <(find_phase_files Y0)
mapfile -t y1_files < <(find_phase_files Y1)

echo "Files per phase: N0=${#n0_files[@]} N1=${#n1_files[@]} Y0=${#y0_files[@]} Y1=${#y1_files[@]}"
echo "Output: $short_fname"

# ── summarize ─────────────────────────────────────────────────────

> "$short_fname"

echo "Summarizing disabled (N0/N1)..."
before_disabled=$(summarize_files "${n0_files[@]}")
after_disabled=$(summarize_files "${n1_files[@]}")
delta_disabled=$(compute_delta "$before_disabled" "$after_disabled")

write_section "DISABLED: before workload" "$before_disabled"
write_section "DISABLED: after workload"  "$after_disabled"
write_section "DISABLED: delta"           "$delta_disabled"

echo "Disabled delta:"
echo "$delta_disabled" | jq '{
  read_txns_created:       .read_transactions.created,
  read_invalidations:      .read_invalidations.total,
  invalidation_rate_pct:   .read_transactions.invalidation_rate_pct,
  lazy_skipped_regs:       .lazy_read.skipped_registrations,
  lazy_stale_retries:      .lazy_read.stale_retries,
  read_lat_avg_ms:         .read_latency.avg_ms,
  conflict_replays:        .conflict_replays.total_replays
}'

echo ""
echo "Summarizing enabled (Y0/Y1)..."
before_enabled=$(summarize_files "${y0_files[@]}")
after_enabled=$(summarize_files "${y1_files[@]}")
delta_enabled=$(compute_delta "$before_enabled" "$after_enabled")

write_section "ENABLED: before workload"  "$before_enabled"
write_section "ENABLED: after workload"   "$after_enabled"
write_section "ENABLED: delta"            "$delta_enabled"

echo "Enabled delta:"
echo "$delta_enabled" | jq '{
  read_txns_created:       .read_transactions.created,
  read_invalidations:      .read_invalidations.total,
  invalidation_rate_pct:   .read_transactions.invalidation_rate_pct,
  lazy_skipped_regs:       .lazy_read.skipped_registrations,
  lazy_stale_retries:      .lazy_read.stale_retries,
  read_lat_avg_ms:         .read_latency.avg_ms,
  conflict_replays:        .conflict_replays.total_replays
}'

# ── comparison ────────────────────────────────────────────────────

echo ""
echo "======== COMPARISON ========"
comparison=$(jq -n --argjson d "$delta_disabled" --argjson e "$delta_enabled" '
  def safe_div(n; d): if d > 0 then (n / d * 10000 | round / 10000) else 0 end;
  def pct_change(old; new): if old != 0 then ((new - old) / old * 10000 | round / 100) else null end;
  {
    read_invalidations: {
      disabled:   $d.read_invalidations.total,
      enabled:    $e.read_invalidations.total,
      change_pct: pct_change($d.read_invalidations.total; $e.read_invalidations.total)
    },
    invalidation_rate_pct: {
      disabled: $d.read_transactions.invalidation_rate_pct,
      enabled:  $e.read_transactions.invalidation_rate_pct
    },
    lazy_read: {
      skipped_registrations: $e.lazy_read.skipped_registrations,
      stale_retries:         $e.lazy_read.stale_retries,
      cursor_refreshes:      $e.lazy_read.cursor_refreshes,
      skips_per_read_txn:    safe_div($e.lazy_read.skipped_registrations;
                                      $e.read_transactions.created)
    },
    read_latency_avg_ms: {
      disabled:   $d.read_latency.avg_ms,
      enabled:    $e.read_latency.avg_ms,
      change_pct: pct_change($d.read_latency.avg_ms; $e.read_latency.avg_ms)
    },
    conflict_replays: {
      disabled:   $d.conflict_replays.total_replays,
      enabled:    $e.conflict_replays.total_replays,
      change_pct: pct_change($d.conflict_replays.total_replays;
                             $e.conflict_replays.total_replays)
    },
    read_lat_histogram: {
      disabled: $d.read_latency.histogram,
      enabled:  $e.read_latency.histogram
    }
  }')

write_section "COMPARISON (disabled vs enabled)" "$comparison"

echo "$comparison" | jq 'del(.read_lat_histogram)'
echo ""
echo "Read latency histogram (disabled vs enabled):"
echo "$comparison" | jq -r '
  .read_lat_histogram |
  if (.disabled | type) != "array" or (.enabled | type) != "array"
  then "  (no histogram data)"
  elif (.disabled | length) == 0 or (.enabled | length) == 0
  then "  (no histogram data)"
  elif (.disabled | length) != (.enabled | length)
  then "  (bucket count mismatch: disabled=\(.disabled | length), enabled=\(.enabled | length) -- rebuild with matching histogram buckets)"
  else . as $h |
    "  Bucket     | Disabled     | Enabled",
    "  -----------+--------------+-----------",
    (range($h.disabled | length) |
      . as $i |
      "  <= \($h.disabled[$i].le | tostring | .[0:7] | . + "       "[.[0:7] | length:])ms | \($h.disabled[$i].count | tostring | . + "            "[.[0:12] | length:]) | \($h.enabled[$i].count)"
    )
  end'

echo ""
echo "Done. Full results in: $short_fname"
