# PyFLEXTRKR + DaYu — validated scales (PNNL Deception)

| Files | Nodes × workers | Result | DaYu traces |
|---:|---|---|---|
| 6   | 4 × 8  | ✅ all 9 stages, exit 0 | VOL+VFD valid |
| 48  | 48 × 4 | ✅ all 9 stages, exit 0 | VOL 77/77, VFD 73/75 |
| 480 | 80 × 3 | ✅ all 9 stages, exit 0 (after VFD fix) | VOL 81/82, VFD 81/81 |
| 962 | 80 × 3 | ✅ all 9 stages, exit 0, 41 min | VOL 102/102, VFD 100/101 |

3 DaYu source fixes upstreamed to grc-iit/dayu (branch fix/vol-stat-finalize-on-teardown):
  1b1d04c VOL stat-file finalize on teardown/SIGTERM (+ empty array)
  ee86309 VOL strdup NULL guards (dataset-close crash)
  49b85b2 VFD GetDsetName mmap-leak + MAP_FAILED guard (cumulative scale crash) <- the big one
Open follow-ups (lower priority): VFD finalize-on-abrupt-kill (clean traces on crash);
DaYu sankey renderer hang (DAYU_SANKEY_VIZ_TODO.md).

## (separate, earlier) nf-core_methylseq #27: Class C / Nextflow+HQ port proven; DataLife task hang (separate debug)
