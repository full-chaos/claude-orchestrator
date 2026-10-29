# pm lane common brief (2026-10-29)

Lead = "main" (the pm orchestrator). Report to main only, ONE report per stop (<= 25 lines, facts + paths + shas). PARK on waits. No sub-agents.

HARD RULES
- Secrets live only in 0600 files. Never put a secret in chat, argv, logs or Linear. No env dumps (no bare `export`, `env`, `printenv`).
- No prod: no kubectl against prod, no prod DB, no prod URLs. Proofs run locally on this host or in CI.
- Linear: read-only (get_issue, list_comments). main posts comments.
- GitHub: read + your own PR branch only. Signed commits. No --no-verify. Force push only to your own PR branch with --force-with-lease.
- Repo /home/ubuntu/devhealth/ops has .codegraph/: use `codegraph explore -p /home/ubuntu/devhealth/ops "<symbols or question>"` FIRST for any code question; grep only if it is empty.
- TMPDIR=<lane dir>/tmp (export it in every shell; D6448). Every `go test` runs under `/home/ubuntu/devhealth/scripts/capped.sh -- go test ...` with -timeout. Leave 0 stray processes and 0 testcontainers.

LANE SETUP
- Lane dir: /var/lib/oci-cache/lane-scratch/pm-<ticket>/ (mkdir -p; tmp/, logs/).
- Clone: `git clone --reference /home/ubuntu/devhealth/ops https://github.com/full-chaos/dev-health-ops.git ops`, branch from origin/main with a neutral name (no ticket id in the branch name is fine). Never use another lane's clone or worktree.
- Keep <lane dir>/PICKUP.md current (what is done, next step, paths), so a restart can resume.

PROCESS
1. Read the ticket + comments. Write <lane dir>/PLAN-<ticket>.md (<= 60 lines): files + file:line at origin/main (state the sha), the change, the red test(s), local proof commands, risks/overlap with open PRs touching the same files (`gh pr list --state open --search "<path>"`, GET only). Send main the PLAN path + sha256, then CONTINUE (no wait) unless the plan found a blocker or a scope question.
2. Red first: add the test, run it, record the red output (log + sha256). Then the fix; run the proof green. Keep the red run log.
3. Gate before PR: `/home/ubuntu/devhealth/scripts/capped.sh -- go run ./cmd/cigate plan-reads --root . --reach` rc 0 (if it asks for a write: `plan-reads --write`, own commit). `go vet ./...` on touched packages; `gofmt -l` clean.
4. PR: `gh pr create --draft`. Title = one line naming the change (test-only tickets may carry the CHAOS id in the title: they are done at merge). Body: first line "Linear CHAOS-<ticket>" (or "Part of CHAOS-<parent>" if the ticket names one), then WHAT / WHY / PROOF (red log sha, green log sha) / RISK-NOTES. Save the body to <lane dir>/pr-body-1.md and also to ops/.codex-review-context.md (byte-equal to the live body; do not commit that file).
5. Codex round of record: launcher = /home/ubuntu/devhealth/scripts/codex-review/codex-review.sh.v4.8.33-720a36c9 (the newest codex-review.sh.v4.* in that dir; never the stale copies under .remember/lanes/_shared or lane-scratch/_shared); read /home/ubuntu/devhealth/.remember/lanes/_briefs/codex-output-contract.md first. Prompt = /home/ubuntu/devhealth/.remember/lanes/_briefs/codex-review-prompt-of-record.md VERBATIM (fill brackets only; no file list). Output dir -o /home/ubuntu/devhealth/_records/round-pm-<ticket>-r<N>/. Cap: 4 rounds (D6439). Report the verdict path + sha256 + P-list to main after each round. On NOT CLEAN: fix P1/P2 that are real, re-run; P3 = record in the body. Do not start round 3+ without main's word.
6. Ship: test-only or CI-only change = ships on a CLEAN round (D6436). Runtime code = main routes ONE peer lead check first; do not merge until main says "peer OK".
   Merge: `gh pr ready`, wait CI green, then `/var/lib/oci-cache/lane-scratch/shared/mergegate-mq.sh final ops <PR#> <head sha>` (read its header first; standing yes D6434). Report PR number, head sha, merge sha, patch-id check to main.
7. Clean up: remove the lane clone's build artefacts, keep logs and PLAN/PICKUP. Report "leftovers = 0".
