# Clean-host validation implementation plan

**Goal:** publish a standalone tuner whose defaults follow the clean-host evidence and whose queue updates survive repeated application and rollback.

**Architecture:** preserve the existing transaction/snapshot engine. Parameterize congestion/queue policy with balanced and explicit bbr profiles. Keep lab orchestration and generated secrets outside the repository.

**Tech stack:** Bash 5, iproute2, systemd, Python stdlib integration tests; Ubuntu 24.04 native test host.

- [x] Capture untouched host metadata and later 1 GiB boot-limit metadata before tuning.
- [x] Establish 30 independent UUID mappings, host-networked Xray and a separate HTTPS payload origin; verify authenticated transfer.
- [x] Run stock, forced BBR/fq, isolated candidate and rate-limited comparison loads; retain per-flow and node/generator samples.
- [x] Fix pacing, modern fq parsing, native handle/immutable-flow behavior and template limits. Test original failures before the fixes.
- [x] Add balanced/default and bbr policies, validating inputs before mutation and keeping snapshot compatibility.
- [x] Run syntax, ShellCheck, full integration tests, native root/mq tests and independent review.
- [x] Compare the final balanced profile under 30 sustained transfers and verify live reapply/revert/reboot.
- [x] Remove temporary exposed services, generated credentials and SSH keys; restore the original memory boot configuration.
- [x] Refresh tune.sh, archive, patch, hashes and the evidence-based report.
