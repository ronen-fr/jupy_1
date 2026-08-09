#!/bin/bash
# rebalance_bench.sh
#
# Collect LBA btree rebalance metrics in four phases: F-T-T-F
# (seastore_lba_background_rebalance = false, true, true, false).
# The repeated inner pair (T-T, F-F) lets the second run of each
# mode start from a steady-state tree shape, avoiding transient
# effects from the mode switch.
#
# Outputs:
#   /tmp/${fname}_<osd>_<phase>.json  - raw per-OSD dump_metrics
#   /tmp/${fname}_final.txt           - aggregated summary with deltas
#
# Usage:
#   NUM_OSDS=3 WORKLOAD=~/src/matan_scr2.sh bash ~/src/rebalance_bench.sh

set -euo pipefail

NUM_OSDS=${NUM_OSDS:-3}
WORKLOAD=${WORKLOAD:-~/src/matan_scr2.sh}
SETTLE_SECS=${SETTLE_SECS:-5}
JQ_SUMMARIZE=~/src/summarize_rebalance_metrics.jq

fname="rebal_$(date +%d_%H%M)"
short_fname="/tmp/${fname}_final.txt"
echo "Run tag: $fname"
echo "Summary file: $short_fname"

# -- build OSD list --------------------------------------------------------
OSDS=()
for ((i = 0; i < NUM_OSDS; i++)); do
  OSDS+=("$i")
done
echo "OSDs: ${OSDS[*]}"
echo "Workload: $WORKLOAD"
echo "Settle time: ${SETTLE_SECS}s"

# -- helpers ---------------------------------------------------------------

dump_all_osds() {
  local phase=$1
  for id in "${OSDS[@]}"; do
    local outf="/tmp/${fname}_osd${id}_${phase}.json"
    echo "dumping osd.${id} ${phase}" > "$outf"
    bin/ceph tell "osd.${id}" dump_metrics --format=json-pretty >> "$outf"
  done
}

set_all_osds() {
  local key=$1 val=$2
  for id in "${OSDS[@]}"; do
    ceph tell "osd.${id}" config set "$key" "$val" 2>/dev/null
  done
}

summarize_phase() {
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
  local header=$1 json=$2
  echo "" >> "$short_fname"
  echo "=== $header ===" >> "$short_fname"
  echo "$json" >> "$short_fname"
}

compute_delta() {
  local before=$1 after=$2
  jq -n --argjson before "$before" --argjson after "$after" '
  def safe_div(n; d): if d > 0 then (n / d * 10000 | round / 10000) else 0 end;

  ($after.transactions.mutate_created    - $before.transactions.mutate_created) as $d_mutate |
  ($after.transactions.rebalance_created - $before.transactions.rebalance_created) as $d_rebalance |

  ($after.lba_splits.reactive  - $before.lba_splits.reactive)  as $d_splits_reactive |
  ($after.lba_splits.proactive - $before.lba_splits.proactive) as $d_splits_proactive |
  ($after.lba_merges.reactive  - $before.lba_merges.reactive)  as $d_merges_reactive |
  ($after.lba_merges.proactive - $before.lba_merges.proactive) as $d_merges_proactive |

  ($after.lba_splits.invalidated_reactive    - $before.lba_splits.invalidated_reactive) as $d_splits_inval_reactive |
  ($after.lba_splits.invalidated_proactive   - $before.lba_splits.invalidated_proactive) as $d_splits_inval_proactive |
  ($after.lba_merges.invalidated_proactive   - $before.lba_merges.invalidated_proactive) as $d_merges_inval_proactive |

  ($after.lba_tree.extents_num - $before.lba_tree.extents_num) as $d_extents |
  ($after.lba_tree.inserts     - $before.lba_tree.inserts)     as $d_inserts |
  ($after.lba_tree.erases      - $before.lba_tree.erases)      as $d_erases |

  ($after.conflicts.involving_mutate    - $before.conflicts.involving_mutate)    as $d_conflicts_mutate |
  ($after.conflicts.involving_rebalance - $before.conflicts.involving_rebalance) as $d_conflicts_rebalance |
  ($after.conflicts.total               - $before.conflicts.total)               as $d_conflicts_total |

  ($after.conflict_replays.total_replays - $before.conflict_replays.total_replays) as $d_replays |

  ($after.write_latency.total_ops - $before.write_latency.total_ops) as $d_write_ops |
  ($after.write_latency.total_ms  - $before.write_latency.total_ms)  as $d_write_ms |
  ($after.read_latency.total_ops  - $before.read_latency.total_ops)  as $d_read_ops |
  ($after.read_latency.total_ms   - $before.read_latency.total_ms)   as $d_read_ms |

  # per-bucket histogram delta
  (if ($after.write_latency.histogram | length) > 0
       and ($before.write_latency.histogram | length) > 0
   then [ range($after.write_latency.histogram | length) | . as $i |
          { le:    $after.write_latency.histogram[$i].le,
            count: ($after.write_latency.histogram[$i].count -
                    $before.write_latency.histogram[$i].count) } ]
   else [] end) as $d_write_hist |

  {
    transactions: {
      mutate:    $d_mutate,
      rebalance: $d_rebalance
    },
    lba_splits: {
      reactive:              $d_splits_reactive,
      proactive:             $d_splits_proactive,
      total:                 ($d_splits_reactive + $d_splits_proactive),
      invalidated_reactive:  $d_splits_inval_reactive,
      invalidated_proactive: $d_splits_inval_proactive
    },
    lba_merges: {
      reactive:              $d_merges_reactive,
      proactive:             $d_merges_proactive,
      total:                 ($d_merges_reactive + $d_merges_proactive),
      invalidated_proactive: $d_merges_inval_proactive
    },
    lba_tree: {
      extents_num_delta:     $d_extents,
      inserts:               $d_inserts,
      erases:                $d_erases,
      splits_per_insert_pct: safe_div($d_splits_reactive * 100; $d_inserts)
    },
    conflicts: {
      involving_mutate:    $d_conflicts_mutate,
      involving_rebalance: $d_conflicts_rebalance,
      total:               $d_conflicts_total,
      replays:             $d_replays
    },
    write_latency: {
      total_ops:  $d_write_ops,
      total_ms:   ($d_write_ms * 10000 | round / 10000),
      avg_ms:     safe_div($d_write_ms; $d_write_ops),
      histogram:  $d_write_hist
    },
    read_latency: {
      total_ops:  $d_read_ops,
      total_ms:   ($d_read_ms * 10000 | round / 10000),
      avg_ms:     safe_div($d_read_ms; $d_read_ops)
    }
  }'
}

run_phase() {
  # run_phase <label> <rebalance_bool> <tag0> <tag1>
  local label=$1 rebal=$2 tag0=$3 tag1=$4

  echo ""
  echo "======== PHASE: $label (rebalance=$rebal) ========"
  set_all_osds seastore_lba_background_rebalance "$rebal"
  echo "Waiting ${SETTLE_SECS}s for config to take effect..."
  sleep "$SETTLE_SECS"

  echo "Collecting 'before' metrics..."
  dump_all_osds "$tag0"
  local before
  before=$(summarize_phase "$tag0")

  echo "Running workload: $WORKLOAD"
  bash "$WORKLOAD"

  echo "Collecting 'after' metrics..."
  dump_all_osds "$tag1"
  local after
  after=$(summarize_phase "$tag1")

  local delta
  delta=$(compute_delta "$before" "$after")

  write_section "$label: before" "$before"
  write_section "$label: after"  "$after"
  write_section "$label: delta"  "$delta"

  echo "$delta" | jq '{
    mutate_txns:       .transactions.mutate,
    rebalance_txns:    .transactions.rebalance,
    reactive_splits:   .lba_splits.reactive,
    proactive_splits:  .lba_splits.proactive,
    reactive_merges:   .lba_merges.reactive,
    proactive_merges:  .lba_merges.proactive,
    conflicts_total:   .conflicts.total,
    replays:           .conflicts.replays,
    write_lat_avg_ms:  .write_latency.avg_ms,
    read_lat_avg_ms:   .read_latency.avg_ms
  }'

  # export for comparison
  printf -v "${label}_delta" '%s' "$delta"
}

# -- Four phases: F - T - T - F --------------------------------------------

run_phase "OFF_1" false "F1_0" "F1_1"
run_phase "ON_1"  true  "T1_0" "T1_1"
run_phase "ON_2"  true  "T2_0" "T2_1"
run_phase "OFF_2" false "F2_0" "F2_1"

# -- Warm-up deltas (informational only) ------------------------------------

delta_off1=$(compute_delta "$(summarize_phase F1_0)" "$(summarize_phase F1_1)")
delta_on1=$(compute_delta "$(summarize_phase T1_0)" "$(summarize_phase T1_1)")

echo ""
echo "======== WARM-UP RUNS (informational) ========"
echo "--- OFF_1 ---"
echo "$delta_off1" | jq '{
  mutate_txns:      .transactions.mutate,
  rebalance_txns:   .transactions.rebalance,
  reactive_splits:  .lba_splits.reactive,
  proactive_splits: .lba_splits.proactive,
  reactive_merges:  .lba_merges.reactive,
  proactive_merges: .lba_merges.proactive,
  conflicts_total:  .conflicts.total,
  replays:          .conflicts.replays,
  write_lat_avg_ms: .write_latency.avg_ms,
  read_lat_avg_ms:  .read_latency.avg_ms
}'
echo "--- ON_1 ---"
echo "$delta_on1" | jq '{
  mutate_txns:      .transactions.mutate,
  rebalance_txns:   .transactions.rebalance,
  reactive_splits:  .lba_splits.reactive,
  proactive_splits: .lba_splits.proactive,
  reactive_merges:  .lba_merges.reactive,
  proactive_merges: .lba_merges.proactive,
  conflicts_total:  .conflicts.total,
  replays:          .conflicts.replays,
  write_lat_avg_ms: .write_latency.avg_ms,
  read_lat_avg_ms:  .read_latency.avg_ms
}'

write_section "WARM-UP OFF_1 delta" "$delta_off1"
write_section "WARM-UP ON_1 delta"  "$delta_on1"

# -- Comparison (second run of each mode = steady state) --------------------

echo ""
echo "======== COMPARISON (steady-state runs: ON_2 vs OFF_2) ========"

# Re-extract the deltas from the saved sections
delta_on=$(compute_delta "$(summarize_phase T2_0)" "$(summarize_phase T2_1)")
delta_off=$(compute_delta "$(summarize_phase F2_0)" "$(summarize_phase F2_1)")

comparison=$(jq -n --argjson off "$delta_off" --argjson on "$delta_on" '
  def safe_div(n; d): if d > 0 then (n / d * 10000 | round / 10000) else 0 end;
  def pct_change(old; new): if old != 0 then ((new - old) / old * 10000 | round / 100) else null end;
  {
    reactive_splits: {
      off:        $off.lba_splits.reactive,
      on:         $on.lba_splits.reactive,
      change_pct: pct_change($off.lba_splits.reactive; $on.lba_splits.reactive)
    },
    proactive_splits: {
      off: $off.lba_splits.proactive,
      on:  $on.lba_splits.proactive
    },
    reactive_merges: {
      off:        $off.lba_merges.reactive,
      on:         $on.lba_merges.reactive,
      change_pct: pct_change($off.lba_merges.reactive; $on.lba_merges.reactive)
    },
    conflicts: {
      off:        $off.conflicts.total,
      on:         $on.conflicts.total,
      change_pct: pct_change($off.conflicts.total; $on.conflicts.total)
    },
    replays: {
      off:        $off.conflicts.replays,
      on:         $on.conflicts.replays,
      change_pct: pct_change($off.conflicts.replays; $on.conflicts.replays)
    },
    mutate_conflict_rate_pct: {
      off: safe_div($off.conflicts.involving_mutate * 100; $off.transactions.mutate),
      on:  safe_div($on.conflicts.involving_mutate * 100; $on.transactions.mutate)
    },
    write_latency_avg_ms: {
      off:        $off.write_latency.avg_ms,
      on:         $on.write_latency.avg_ms,
      change_pct: pct_change($off.write_latency.avg_ms; $on.write_latency.avg_ms)
    },
    read_latency_avg_ms: {
      off:        $off.read_latency.avg_ms,
      on:         $on.read_latency.avg_ms,
      change_pct: pct_change($off.read_latency.avg_ms; $on.read_latency.avg_ms)
    },
    write_lat_histogram: {
      off: $off.write_latency.histogram,
      on:  $on.write_latency.histogram
    }
  }')

write_section "COMPARISON (ON_2 vs OFF_2)" "$comparison"
echo "$comparison" | jq 'del(.write_lat_histogram)'

echo ""
echo "Write latency histogram (OFF vs ON):"
echo "$comparison" | jq -r '
  .write_lat_histogram |
  if (.off | type) != "array" or (.on | type) != "array"
  then "  (no histogram data)"
  elif (.off | length) == 0 or (.on | length) == 0
  then "  (no histogram data)"
  elif (.off | length) != (.on | length)
  then "  (bucket count mismatch)"
  else . as $h |
    "  Bucket     | OFF          | ON",
    "  -----------+--------------+-----------",
    (range($h.off | length) |
      . as $i |
      "  <= \($h.off[$i].le | tostring | .[0:7] | . + "       "[.[0:7] | length:])ms | \($h.off[$i].count | tostring | . + "            "[.[0:12] | length:]) | \($h.on[$i].count)"
    )
  end'

echo ""
echo "Done. Full results in: $short_fname"
echo "Raw per-OSD dumps in: /tmp/${fname}_osd*_*.json"
