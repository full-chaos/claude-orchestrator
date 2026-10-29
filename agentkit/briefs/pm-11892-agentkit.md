# pm lane: CHAOS-11892 agent-kit collection (chris ask 2026-10-29 19:3xZ)
Common brief: /home/ubuntu/devhealth/.remember/program-manager/briefs/pm-lane-common-2026-10-29.md (secrets, no prod, Linear read-only, report form). This lane writes NO ops/deploy code; it collects scripts into ONE repo.
Lane dir: /var/lib/oci-cache/lane-scratch/pm-11892/

chris: "collect the normalized scripts we've been using into a single place ... commit anything that's part of our agent orchestration/development workflow into a single repo." An earlier attempt exists: github.com/full-chaos/claude-orchestrator (last update 2026-10-03). Read it first (`gh repo view full-chaos/claude-orchestrator`, clone to <lane dir>/claude-orchestrator, read its README + tree). If it is the right home, build on it; if it is dead or a different thing, say so in the PLAN and propose the layout for a fresh branch in it anyway (pm decides the repo; do not create a new GitHub repo).

## Step 1: inventory (read-only) -> PLAN-11892.md (<= 80 lines), send path + sha256, CONTINUE
Scripts of record today (verify each exists; record path, version, sha256, size, last-modified, purpose from its header; mark which copies are stale duplicates):
- Codex review: /home/ubuntu/devhealth/scripts/codex-review/ (codex-review.sh.v4.8.33-720a36c9 current; v4.8.22..32 older; bigboy-start-gate.sh.v11 + v10; test-*.sh; VET-CHECKLIST.md; README.md); the stale copies in /home/ubuntu/.local/lib/dev-health-review/ (codex-review.sh + .bak, verify-round-repros.py), /home/ubuntu/devhealth/.remember/lanes/_shared/codex-review.sh.v4.8.2*, /var/lib/oci-cache/lane-scratch/_shared/codex-review.sh.v4.8.1*, /home/ubuntu/devhealth/scripts/codex-review.sh.RETIRED-2026-09-18.
- Review prompt + contract: /home/ubuntu/devhealth/.remember/lanes/_briefs/codex-review-prompt-of-record.md, codex-output-contract.md.
- Merge: /var/lib/oci-cache/lane-scratch/shared/mergegate-mq.sh (of record), mergegate.sh, gatedmerge.sh, mergegate_test.sh (+ .bak/.sha copies).
- Prod roll kit: /var/lib/oci-cache/lane-scratch/shared/prodroll.sh (v3j) and prodroll-v3/ (ROLL-24d.sh, POSTROLL-24d.sh, LOGWATCH-24d.sh, HEADROOM-24d.sh, RENDER-PATHS-24d.sh, PODSNAP-CMP-r7.sh, READBACK-IMG.sh, START-CHECK-IMG.sh, REFRESH-KIT-v2.sh, full-render-diff.py, f1pipe-11709.sh, DESIGN.md, SHA256SUMS, tests/, examples/; ssh_config + known_hosts = CHECK for host secrets before copying); prodroll-v1/, prodroll-v3.*-old = stale.
- CI checks: shared/pcheck.sh, mcheck.sh, mcheck_nonpass_test.sh, known-red.tsv (+ .bak copies = stale).
- Go test wrapper: /home/ubuntu/devhealth/scripts/capped.sh (+ .bak = stale).
- Tools: shared/tools/ (actionlint, shellcheck binaries: do NOT commit binaries; record versions + a fetch script).
- Lane brief templates worth keeping as docs: /home/ubuntu/devhealth/.remember/program-manager/briefs/pm-lane-common-2026-10-29.md, scribe-pm.md; /home/ubuntu/devhealth/.remember/lanes/_briefs/resume-common-2026-09-10.md.
- Also look (read-only) in /home/ubuntu/devhealth/lib.sh, /home/ubuntu/devhealth/scripts/, and each lead's _briefs for any other script every lane calls (list, do not copy yet).
SECRETS: grep every candidate for key material (sk-, lin_api, ghp_, AKIA, BEGIN PRIVATE, password=, token=, long base64); a hit = exclude the file and name it in the PLAN (never print the value). ssh_config/known_hosts: include only if they hold hostnames and public host keys, no private material.

## Step 2: build the kit on a branch of claude-orchestrator
Layout (adjust if the repo has one): review/ (launcher at its real version name + a `current` symlink, prompt-of-record, output contract, vet checklist, self-tests), merge/ (mergegate-mq.sh + test), prodroll/ (prodroll.sh + the v3 sub-scripts + DESIGN.md + tests + SHA256SUMS), ci/ (pcheck, mcheck, known-red.tsv, capped.sh), briefs/ (the lane templates), tools/ (versions + fetch script), INDEX.md (one line per tool: path, version, sha256, purpose, where it runs from today), CHANGELOG.md (this import: source path -> repo path, sha256). Copy bytes unchanged (no edits to scripts); keep the version suffix in the file name. `git add` only the files you listed; `git status` before commit; signed commits; branch `agentkit-import-2026-10-29`; push; `gh pr create --draft` with the INDEX as the body. Do NOT merge. Do NOT delete or move anything outside the lane dir.

Report to main (<= 25 lines): PLAN sha, repo verdict (claude-orchestrator right home or not), file count + total size, secrets scan result (counts only), PR number + head sha, what was excluded and why.
