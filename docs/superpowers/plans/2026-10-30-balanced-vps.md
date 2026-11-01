# Balanced VPS tuning Implementation Plan

> **For agentic workers:** Execute the core implementation as one isolated task, review spec compliance, then review quality. User has authorized continuous execution.

**Goal:** Replace unsafe unconditional tuning with validated, reversible tuning for small Ubuntu exit nodes, and measure it on the authorized lab server.

**Architecture:** Keep tune.sh self-contained; generated helper owns queue persistence. Diagnostics are read-only. A root-owned state directory stores an original snapshot plus a per-apply rollback checkpoint. Benchmarking is a separate opt-in script.

**Tech Stack:** Bash 5, iproute2, systemd, Linux proc/sysfs; Python standard library for test summaries only.

### Task 1: Core tuner and regression coverage
- [x] Replace tune.sh using the accepted design; preserve its standalone download workflow.
- [x] Add tests exercising invalid input, no mutations in dry run, calculation on 1 GiB, repeated apply, exact file/sysctl restoration, unsupported BBR/qdisc, and injected failure.
- [x] Run `bash -n tune.sh` and ShellCheck, then regression tests.

### Task 2: Controlled experiments
- [x] Record original server: Ubuntu 24.04, 1 vCPU, approximately 2 GiB RAM, old tuner already installed, pfifo_fast still active.
- [x] Install lab tools and run reproducible namespace tests at controlled RTT/bottleneck; compare CUBIC/pfifo, BBR/pfifo, BBR/fq including loaded ping.
- [x] Test actual-host apply/reapply/revert and boot persistence; clearly label inherited legacy values.
- [x] Keep raw measurements under work and an anonymized report under docs.

### Task 3: Documentation, CI, delivery
- [x] Rewrite README in Russian around actual defaults, commands, limitations and measurement.
- [x] Add Ubuntu CI running syntax/ShellCheck/tests.
- [x] Review spec compliance, then code quality, address findings and rerun relevant checks.
- [x] Produce a downloadable repository archive and patch in outputs, plus test report; leave the test server in the verified tuned state.
