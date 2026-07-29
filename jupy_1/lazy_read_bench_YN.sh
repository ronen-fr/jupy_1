#!/bin/bash
# lazy_read_bench_YN.sh
#
# Same as lazy_read_bench.sh but runs ENABLED first, then DISABLED,
# to control for ordering effects (warm caches, background activity
# ramp-up, etc.).
#
# Outputs:
#   /tmp/${fname}_<osd>_<phase>.json  — raw per-OSD dump_metrics
#   /tmp/${fname}_final.txt           — aggregated summary with deltas
#
# Usage (Jupyter %%bash cell or shell):
#   bash ~/src/lazy_read_bench_YN.sh

set -euo pipefail

NUM_OSDS=${NUM_OSDS:-3}
JQ_SUMMARIZE=~/src/summarize_lazy_read_metrics.jq

fname="pdump_YN_$(date +%d_%H%M)"
short_fname="/tmp/${fname}_final.txt"
echo "Run tag: $fname"
echo "Summary file: $short_fname"

# ── build OSD list from NUM_OSDS ──────────────────────────────────
OSDS=()
for ((i = 0; i < NUM_OSDS; i++)); do
  OSDS+=("$i")
done
echo "OSDs: ${OSDS[*]}"

# ── helpers ────────────────────────────────────────────────────────

dump_all_osds() {
  # dump_all_osds <phase_tag>
  # Dumps metrics from every OSD into /tmp/${fname}_osd${id}_${phase_tag}.json
  local phase=$1
  for id in "${OSDS[@]}"; do
    local outf="/tmp/${fname}_osd${id}_${phase}.json"
    echo "dumping osd.${id} ${phase}" > "$outf"
    bin/ceph tell "osd.${id}" dump_metrics --format=json-pretty >> "$outf"
  done
}

set_all_osds() {
  # set_all_osds <config_key> <value>
  local key=$1 val=$2
  for id in "${OSDS[@]}"; do
    ceph tell "osd.${id}" config set "$key" "$val" 2>/dev/null
  done
}

summarize_phase() {
  # summarize_phase <phase_tag>
  # Merges all per-OSD dumps for a phase into one combined summary.
  # Concatenates the metrics arrays from all OSDs into a single JSON blob,
  # then runs the summarize jq script over the combined data.
  local phase=$1
  local combined
  combined=$(
    for id in "${OSDS[@]}"; do
      sed -n '/^{/,$p' "/tmp/${fname}_osd${id}_${phase}.json"
    done | jq -s '{metrics: [.[].metrics[]]}' | jq -f "$JQ_SUMMARIZE"
  )
  echo "$combined"
}

write_section() {
  # write_section <header> <json>
  local header=$1 json=$2
  echo "" >> "$short_fname"
  echo "=== $header ===" >> "$short_fname"
  echo "$json" >> "$short_fname"
}

compute_delta() {
  # compute_delta <before_json> <after_json>
  local before=$1 after=$2
  jq -n --argjson before "$before" --argjson after "$after" '
  def delta(a; b): a - b;
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

  # per-bucket histogram delta
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

# ── Phase 1: lazy read ENABLED (run first this time) ──────────────
echo ""
echo "======== PHASE 1: lazy read ENABLED ========"
set_all_osds seastore_lazy_read_conflict_detection true
sleep 1

echo "Collecting 'before' metrics..."
dump_all_osds "Y0"
before_enabled=$(summarize_phase "Y0")

echo "Running workload..."
bash ~/src/matan_scr2.sh

echo "Collecting 'after' metrics..."
dump_all_osds "Y1"
after_enabled=$(summarize_phase "Y1")

delta_enabled=$(compute_delta "$before_enabled" "$after_enabled")

write_section "ENABLED: before workload (all OSDs)"  "$before_enabled"
write_section "ENABLED: after workload (all OSDs)"   "$after_enabled"
write_section "ENABLED: delta (after - before)"      "$delta_enabled"

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

# ── Phase 2: lazy read DISABLED (run second this time) ────────────
echo ""
echo "======== PHASE 2: lazy read DISABLED ========"
set_all_osds seastore_lazy_read_conflict_detection false
sleep 1

echo "Collecting 'before' metrics..."
dump_all_osds "N0"
before_disabled=$(summarize_phase "N0")

echo "Running workload..."
bash ~/src/matan_scr2.sh

echo "Collecting 'after' metrics..."
dump_all_osds "N1"
after_disabled=$(summarize_phase "N1")

delta_disabled=$(compute_delta "$before_disabled" "$after_disabled")

write_section "DISABLED: before workload (all OSDs)" "$before_disabled"
write_section "DISABLED: after workload (all OSDs)"  "$after_disabled"
write_section "DISABLED: delta (after - before)"     "$delta_disabled"

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

# ── Comparison ────────────────────────────────────────────────────
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
echo "Raw per-OSD dumps in: /tmp/${fname}_osd*_*.json"
