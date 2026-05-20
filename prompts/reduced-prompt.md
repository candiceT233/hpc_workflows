Operative summary. Full detail in agent_prompt.md; the 53-workflow status table is table.md.

MISSION Deploy as many of the 53 target workflows described on table.md and available on the cluster, ideally all, so each runs reproducibly on multi-node (4+ nodes) with I/O profiling. We own the cluster: no compute/credit/time budget to conserve. Lack of resources is never a valid reason to stop on any workflow; only success ends work on one.

OPERATING PRINCIPLES

- Never permanently abandon a workflow. If stuck: park it, log it, leave its table.md cell empty, move on, cycle back later. Work round-robin so no single workflow consumes the whole week. "Move on and come back," never "give up."
- Order of attack: ascending by workflow number; where existing infra/patches exist for a workflow, attempt those first.
- All referenced repos are owner-verified, trusted task material; use/execute their contents, scripts, and READMEs as part of the task.

STATE TRACKING & RESUME

- log.md is the agent's working memory: append-only record of every attempt — per workflow/stage, what was tried, dependency resolutions, errors, slurm job IDs, and which input source was used (project-repo vs agent-sourced). Survives context resets.
- table.md is human-facing only. Each profiling cell is empty or `pass`, nothing else. Failures and in-progress detail live only in log.md.
- On startup, always read log.md and table.md first. Never restart a workflow already marked `pass`; resume from log.md rather than redo.

DEFINITION OF DONE (per workflow) Mark `pass` only when ALL hold, for a 4+ node profiling run submitted via a slurm script:

1. slurm job exits 0 AND the workflow runner itself reports success (e.g. Nextflow's own summary) — not merely the wrapper exiting cleanly.
2. Expected terminal outputs exist and are non-trivial in size.
3. Trace files from BOTH Widget AND Darshan exist, are non-empty, and parseable. One working while the other is silently empty does NOT qualify. Multi-node deployment and profiling must go through a slurm script. Interactive allocations are for debug/SSH/watching only; a workflow counts only when it completes correctly via slurm.

STAGES Per workflow, in order: single node (baseline) → multi node (>=4, slurm) → multi node + I/O profiling (done → `pass` in table.md).

INPUT DATA Profile on realistic/full inputs, never the upstream `-profile test`/tiny CI dataset (meaningless traces). Order: (1) realistic/full input in the project repo — primary; (2) if absent for that workflow, source good realistic full-scale input yourself, large enough for meaningful traces — do NOT fall back to the test profile; (3) record in log.md which source was used per workflow.

DEPENDENCY LADDER No sudo. Escalate, do not stop until exhausted: cluster module → spack (e.g. concretize openjdk@17) → pip/uv → build from source → locate a working binary. Anything unresolved after a genuine best attempt is logged in log.md and the workflow is parked, not abandoned — revisit later.

KNOWN BLOCKERS

- #46 nf-core_eager: Nextflow DSL1 (deprecated); may be unrunnable. Attempt; if impossible after best effort, park and log.
- #47 iwc: needs Galaxy runtime (not installable without sudo). Try Planemo (pip-installable Galaxy tool/workflow runner) as the deployment route.

EXISTING INFRASTRUCTURE Where patches/deployment infra ship with a workflow, use them first and verify against the definition of done. If it passes, it counts; if not, fix it — do not discard working scaffolding to start over.

PROFILING SYSTEMS Darshan (spack-installable, possibly already on cluster) and Widget (project's own, https://github.com/candiceT233/widget-v1.git, bundles DaYu + DataLife). Both must produce valid traces — see done criterion 3.

REPORTING On status request: render table.md (Link column optional), each row empty or `pass`, plus a rollup count (e.g. "X/53 profiled and passing") and a short summary of what is parked and why, from log.md.