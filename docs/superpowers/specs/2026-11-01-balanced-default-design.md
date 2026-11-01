# Balanced defaults after clean-host experiments

The user requested continued autonomous improvement and authorized experiments on a second, initially untouched Ubuntu 24.04 VPS. This extends the 2026-10-30 design; the standalone entry point, rollback schema and managed paths stay compatible.

Observed problem: on the measured two-host REALITY/Vision workload, 30 sustained downloads with stock CUBIC/fq_codel achieved approximately 277–292 Mbit/s. Forced BBR/fq achieved approximately 250–254 Mbit/s in the first two runs and did not consistently lower tail latency. This is evidence against prescribing BBR/fq universally, not proof that CUBIC is universally faster.

The default `PROFILE=balanced` preserves the current TCP congestion algorithm and supported existing fq/fq_codel queue settings. It enables fq pacing if disabled. A simple FIFO is replaced with fq when the current congestion algorithm is BBR, otherwise fq_codel. Existing supported default_qdisc values are retained; unsupported legacy defaults receive the matching fallback. `PROFILE=bbr` explicitly selects BBR/fq for operator comparison. Socket maxima remain bounded, initial allocations and aggregate kernel memory heuristics stay untouched.

Queue operations must account for two native kernel constraints: changing qdisc kind cannot reuse its occupied handle, and fq_codel's flow table cannot be reinitialized in place. New kinds get fresh handles; restore must recreate the original supported configuration and explicit handle safely. No-op restoration of an already matching configuration must succeed. Both a simple root and mq leaves require native namespace tests, including apply/revert/apply/revert and rollback before queue modification. Unknown custom topologies remain refused.

Continue preserving unknown template service limits, parse modern fq bands/weights strictly, and explain that existing sockets or application-selected algorithms can differ from the system default. Do not restart Docker automatically. No fixed shaper or TCP_NOTSENT_LOWAT default is added from one experimental run.

Validation: root-owned isolated fixtures and native namespaces, syntax and ShellCheck, old-version snapshot compatibility, clean-host apply/reapply/revert and reboot persistence. Compare external-client 30-UUID workloads with the same source and route. Report physical RAM versus usable memory under the temporary boot limit; report full-stack and generator limitations, sample counts and failures. Do not present these short workloads as a long-term capacity guarantee.
