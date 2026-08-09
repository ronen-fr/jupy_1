# summarize_rebalance_metrics.jq
#
# Aggregate LBA btree rebalance metrics from a Crimson OSD dump_metrics
# JSON blob (summed across all shards).
#
# Usage:
#   tail -n +3 dump_file | jq -f summarize_rebalance_metrics.jq

[.metrics[] | to_entries[]] |

# -- Transaction counts by source -----------------------------------------

  ([ .[] | select(.key == "cache_trans_created"
                   and .value.src == "MUTATE")
         | .value.value ] | add // 0) as $mutate_created |

  ([ .[] | select(.key == "cache_trans_created"
                   and .value.src == "REBALANCE")
         | .value.value ] | add // 0) as $rebalance_created |

# -- LBA tree splits (committed, by source) --------------------------------

  ([ .[] | select(.key == "cache_tree_splits_committed"
                   and .value.tree == "LBA"
                   and .value.src == "MUTATE")
         | .value.value ] | add // 0) as $splits_mutate |

  ([ .[] | select(.key == "cache_tree_splits_committed"
                   and .value.tree == "LBA"
                   and .value.src == "REBALANCE")
         | .value.value ] | add // 0) as $splits_rebalance |

# -- LBA tree merges (committed, by source) --------------------------------

  ([ .[] | select(.key == "cache_tree_merges_committed"
                   and .value.tree == "LBA"
                   and .value.src == "MUTATE")
         | .value.value ] | add // 0) as $merges_mutate |

  ([ .[] | select(.key == "cache_tree_merges_committed"
                   and .value.tree == "LBA"
                   and .value.src == "REBALANCE")
         | .value.value ] | add // 0) as $merges_rebalance |

# -- LBA tree splits/merges (invalidated, by source) ----------------------

  ([ .[] | select(.key == "cache_tree_splits_invalidated"
                   and .value.tree == "LBA"
                   and .value.src == "MUTATE")
         | .value.value ] | add // 0) as $splits_invalidated_mutate |

  ([ .[] | select(.key == "cache_tree_splits_invalidated"
                   and .value.tree == "LBA"
                   and .value.src == "REBALANCE")
         | .value.value ] | add // 0) as $splits_invalidated_rebalance |

  ([ .[] | select(.key == "cache_tree_merges_invalidated"
                   and .value.tree == "LBA"
                   and .value.src == "REBALANCE")
         | .value.value ] | add // 0) as $merges_invalidated_rebalance |

# -- LBA tree extent count -------------------------------------------------

  ([ .[] | select(.key == "cache_tree_extents_num"
                   and .value.tree == "LBA")
         | .value.value ] | add // 0) as $lba_extents_num |

# -- Conflict counts -------------------------------------------------------

  ([ .[] | select(.key == "cache_trans_srcs_invalidated"
                   and (.value.srcs | contains("MUTATE")))
         | .value.value ] | add // 0) as $conflicts_involving_mutate |

  ([ .[] | select(.key == "cache_trans_srcs_invalidated"
                   and (.value.srcs | contains("REBALANCE")))
         | .value.value ] | add // 0) as $conflicts_involving_rebalance |

  ([ .[] | select(.key == "cache_trans_srcs_invalidated")
         | .value.value ] | add // 0) as $conflicts_total |

# -- LBA tree inserts/erases (committed, MUTATE only) ---------------------

  ([ .[] | select(.key == "cache_tree_inserts_committed"
                   and .value.tree == "LBA"
                   and .value.src == "MUTATE")
         | .value.value ] | add // 0) as $inserts_mutate |

  ([ .[] | select(.key == "cache_tree_erases_committed"
                   and .value.tree == "LBA"
                   and .value.src == "MUTATE")
         | .value.value ] | add // 0) as $erases_mutate |

# -- Conflict replay distribution -----------------------------------------

  ([ .[] | select(.key == "seastore_conflict_replay_distribution")
         | .value.value.count ] | add // 0) as $replay_txns |

  ([ .[] | select(.key == "seastore_conflict_replay_distribution")
         | .value.value.sum ] | add // 0) as $replay_total |

# -- DO_TRANSACTION (write) latency ----------------------------------------

  ([ .[] | select(.key == "seastore_op_lat"
                   and .value.latency == "DO_TRANSACTION")
         | .value.value.count ] | add // 0) as $write_ops |

  ([ .[] | select(.key == "seastore_op_lat"
                   and .value.latency == "DO_TRANSACTION")
         | .value.value.sum ] | add // 0) as $write_lat_sum |

  ([ .[] | select(.key == "seastore_op_lat"
                   and .value.latency == "DO_TRANSACTION")
         | .value.value.buckets ] |
   if length == 0 then []
   else
     transpose | map({
       le:    .[0].le,
       count: (map(.count) | add)
     })
   end) as $write_lat_buckets |

# -- READ latency ----------------------------------------------------------

  ([ .[] | select(.key == "seastore_op_lat"
                   and .value.latency == "READ")
         | .value.value.count ] | add // 0) as $read_ops |

  ([ .[] | select(.key == "seastore_op_lat"
                   and .value.latency == "READ")
         | .value.value.sum ] | add // 0) as $read_lat_sum |

{
  transactions: {
    mutate_created:          $mutate_created,
    rebalance_created:       $rebalance_created
  },
  lba_splits: {
    reactive:                $splits_mutate,
    proactive:               $splits_rebalance,
    total:                   ($splits_mutate + $splits_rebalance),
    invalidated_reactive:    $splits_invalidated_mutate,
    invalidated_proactive:   $splits_invalidated_rebalance
  },
  lba_merges: {
    reactive:                $merges_mutate,
    proactive:               $merges_rebalance,
    total:                   ($merges_mutate + $merges_rebalance),
    invalidated_proactive:   $merges_invalidated_rebalance
  },
  lba_tree: {
    extents_num:             $lba_extents_num,
    inserts:                 $inserts_mutate,
    erases:                  $erases_mutate
  },
  conflicts: {
    involving_mutate:        $conflicts_involving_mutate,
    involving_rebalance:     $conflicts_involving_rebalance,
    total:                   $conflicts_total
  },
  conflict_replays: {
    total_transactions:      $replay_txns,
    total_replays:           $replay_total
  },
  write_latency: {
    total_ops:               $write_ops,
    total_ms:                ($write_lat_sum | . * 10000 | round / 10000),
    avg_ms:                  (if $write_ops > 0
                              then ($write_lat_sum / $write_ops
                                    | . * 10000 | round / 10000)
                              else 0 end),
    histogram:               $write_lat_buckets
  },
  read_latency: {
    total_ops:               $read_ops,
    total_ms:                ($read_lat_sum | . * 10000 | round / 10000),
    avg_ms:                  (if $read_ops > 0
                              then ($read_lat_sum / $read_ops
                                    | . * 10000 | round / 10000)
                              else 0 end)
  }
}
