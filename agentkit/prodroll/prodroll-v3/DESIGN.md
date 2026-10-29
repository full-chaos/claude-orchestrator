# prodroll v3f (CHAOS-11788): design for a peer check

v3j = v3i (86e77920, installed) plus the pm ruling after 2 false STOPs (s30-a, s36-a) at I7-topcmp: "compare only rolled groups + 2 samples". User traffic moved the web HPA 3% -> 20% while go-sync rolled; one minute later it was 4%. (1) Rolled only: topcmp gates only the HPAs whose target Deployment (HPA name minus a leading `keda-hpa-`) is in PODSNAP_TARGETS; an HPA not rolled gets a `  NOTE: <hpa> not rolled: ... (no gate)` line (no FAIL/REFUSED/HOLD word). A rolled web HPA must still be readable (as v3i); a rolled KEDA row with `unknown` TARGETS gets a NOTE, no gate. The parse guard (a web HPA row in both files) stays. (2) Two samples: a rolled HPA that moves on sample 1 gives `  MOVED: ...` lines and `TOPCMP: RECHECK (...)`, exit 3; prodroll waits 60 s (`xrun sleep 60`), runs I7-topsnap2 and I7-topcmp2 (mode final), where a move is `TOPCMP: FAIL` (exit 1 = STOP). No move on sample 1: no second sample. `KIT_VERSION=3j`; the pin stays on line 34. Tests: section J (+ the HEADROOM r11-diff check in A).

v3f = v3e (d41977b3, installed, peer-checked by fcdev) plus 3 fixes after the first real v3e pre (11712 step 20, RUN_TAG s20-a, lanes/fcc-window-1028/PRODROLL-roll-dev-health-202727Z.log 796dd3ad) STOPPED on a kit defect at PODSNAP-before: (1) F_POD accepts the padded kubectl columns; (2) every step's final-line regex is audited against REAL prod output, kept as test fixtures (tests/fixtures/real); (3) pm's render rule: the 2 raw renders made with prod values are shredded at the end of their step. `KIT_VERSION=3f`; the pin stays on line 34; same install path, same names. The tests were written first, shown RED against v3e, then GREEN on v3f. See "v3f" below.

v3e = v3d (36f1112d, installed) plus the pm rule for 11712: the docs that leave or enter the render are named exactly in the inputs, and a Secret that leaves the release must stay live. `KIT_VERSION=3e`; the pin stays on line 34. The tests were written first, shown RED against v3d (lanes/fcc-11788/test-v3e-RED-against-v3d-195517Z.log: ok 301 bad 30; the 30 FAILs are the new R4/G2 checks plus the line-1 version check, which now expects v3e), then GREEN on v3e. See "v3e: named docs and kept Secrets" below.

v3d = v3c (ffe34628, installed) plus the pm/D6436 change: the attest is a PEER check by any other lead, not acp only. `KIT_VERSION=3d`; the pin stays on line 34. The tests were written first, shown RED against v3c (lanes/fcc-11788/test-v3d-RED-against-v3c-191120Z.log: the 11 new R3 checks FAIL, plus the line-1 version check, which now expects v3d), then GREEN on v3d. (History: v3c = v3b (cca8ddf9, ATTEST OK, installed) plus acp's two v3b P2 fixes. `KIT_VERSION=3c`. The tests of these fixes were written first, shown RED against v3b (lanes/fcc-11788/test-v3c-RED-against-v3b-185917Z.log: the 7 new R2 tests FAIL, plus the line-1 version check, which now expects v3c), then GREEN on v3c.)

v3b = v3 (82cee47d, refused by acp) plus acp's P1-1, P1-2, P3(a) and P3(b) fixes. `KIT_VERSION=3b`; the kit dir name stays `prodroll-v3` and the install path stays the same. The tests of these fixes were written first, shown RED against v3 (lanes/fcc-11788/test-v3b-RED-against-v3-183443Z.log: 18 FAIL, all of them the new tests), then GREEN on v3b.

## Scope (pm ruling, plain)
prodroll is **NOT a sandbox**. The agent uid has docker, sudo and direct ssh, so a same-uid attacker is out of scope. That includes:
- the same-uid TOCTOU;
- a root install;
- /etc and /opt anchors.

v3 gives two things:
- **ONE stable name** for the permission rule, so that a new script name per roll no longer trips the classifier.
- **Correctness gates**, so that a wrong or stale input, tree, revision or tool result STOPs before or at the prod write.

The inputs file is DATA, never code.

**Install.** At the attest, fcc copies `prodroll.sh` and `prodroll-v3/` from the staging dir `/var/lib/oci-cache/lane-scratch/fcc-11788-v3/` to `/var/lib/oci-cache/lane-scratch/shared/`. There is no sudo and no root step.
- Rule: `Bash(/var/lib/oci-cache/lane-scratch/shared/prodroll.sh:*)`.
- Call form: `/var/lib/oci-cache/lane-scratch/shared/prodroll.sh <sub> <arg> <inputs> [<phase>|<RUN_TAG>]`. There is no `bash` prefix, no cd, no pipe, no redirect and no env.
- After the copy, `head -1` shows `#!/bin/bash -p`, and a usage-error run prints line 1 with the sha of the copied file.

## Every run, in this order
1. `#!/bin/bash -p` (an absolute interpreter; BASH_ENV, ENV, SHELLOPTS and exported functions are ignored).
2. The xtrace guards (rc 10).
3. `PATH=/usr/sbin:/usr/bin:/sbin:/bin`, before any external command.
4. `unset -f` all functions; unset BASH_ENV, ENV, CDPATH and GLOBIGNORE; umask 077.
5. **Self-check, FIRST** (rc 6; acp P1-1 + v3b P2-1). It runs BEFORE the pin line runs. Each of these must hold:
   - Line 1 is exactly `#!/bin/bash -p`.
   - Exactly ONE line of the file starts with `PINNED_SELF_SHA256`, and it is line 34.
   - That line matches `^PINNED_SELF_SHA256=[0-9a-f]{64}$` exactly.
   - sha256 of the file with line 34 deleted BY NUMBER (`sed '34d'`) equals that pin.
   So a trojan on the pin line (`=<pin>; <code>`), a second pin line, or any other edit is refused before it runs.
   Limit, stated plainly: a self-check proves the file, but it cannot stop code placed ABOVE the check, because that code runs first. A same-uid edit is out of scope.
6. **Mode** (rc 6; acp P1-2).
   - **Prod mode:** used when `$0` names PROD_SELF or `readlink -f` resolves to it. `readlink -f $0` must equal PROD_SELF, and no component of PROD_SELF (/var, /var/lib, ..., shared, prodroll.sh) and not the kit dir may be a symlink (`-L` on each).
   - **Copy mode:** any other path. It runs only when all 3 hold (acp v3b P2-2):
     - `PRODROLL_TEST_PATH` is under `/var/lib/oci-cache/lane-scratch/`, and no component starts with `.` (so there is no `..`);
     - `command -v ssh` = `$PRODROLL_TEST_PATH/ssh`;
     - that file is NOT the same file as `/usr/bin/ssh` (`-ef`, which also covers `/bin/ssh` and any link to it).

     This check runs after the argv grammar and before any read of the inputs.

     **What holds exactly:** a copy, or a symlinked install, refuses rc 6 when its ssh is the real `/usr/bin/ssh` (directly, through `/bin`, or through a link), lives outside lane-scratch, or is missing. A prod-mode run never takes a test path.

     **What does not hold:** a FAKE ssh under lane-scratch that itself runs the real ssh is not detected. That is a same-uid file, which is out of scope (pm ruling).
7. The fixed HOME/LANG/LC_ALL/KUBECONFIG; `cd /`. argv: enums only. A usage error hashes only the script (line 1: `sums=- inputs=-`) and exits rc 2.
8. The inputs file is read **once** into a buffer (`read -r -d ''`). Its sha256 is the sha256 of that buffer. A size mismatch means a NUL byte, and the run is REFUSED.
9. Line 1: `PRODROLL v3f sha256(prodroll.sh)=<64> sums=<64> inputs=<path> sha256(inputs)=<64> cmd=<sub args>`. The run log is `lanes/fcc-window-1028/PRODROLL-<sub>-<arg>-<HHMMSS>Z.log` (noclobber, `tee -a`); its last line is `PRODROLL END rc=<n>`.
10. The self-check result (item 5) is printed in the run log.
11. **Kit check** (rc 6): sha256(prodroll-v3/SHA256SUMS) = `PINNED_SUMS_SHA256`, `sha256sum -c --strict` passes, the file set = the SUMS list, and there is no link.
12. **Attest** (rc 2; D6436). The buffer's sha256 must be field 1 of a line in `/home/ubuntu/devhealth/.remember/acr-mcp/lanes/fcc-11788/ATTEST-INPUTS.txt`. A peer lead (any lead except the inputs author) appends `<sha256> <roll> <UTC> <checker>` after its inputs check. The inputs carry `AUTHOR=<lead>` (required, `^[a-z][a-z0-9-]{1,31}$`). Of the lines whose field 1 is the sha, at least one must have exactly 4 fields, a checker (field 4) that matches `^[a-z][a-z0-9-]{1,31}$`, and checker != AUTHOR. So a 3-field line, a bad checker token, or a self-check by the author does not count, and the refusal names each line's reason. The run log prints `ATTEST: ... peer check by <checker> (AUTHOR <author>)`. The file is append-only by convention; prodroll only reads it.
13. **Parse** of the same buffer: the v1 strict reader (key whitelist per target, one regex per key, printable ASCII + LF, no duplicates).
   - RENDER_FILE is also read once; its sha check and its use (I2, via `full-render-diff filter`) take that buffer.
14. **Children:** every child runs under `env -i` + the fixed env. Every ssh is `ssh -F prodroll-v3/ssh_config -o StrictHostKeyChecking=yes -o UserKnownHostsFile=prodroll-v3/known_hosts` with `-n prod`, or with `prod` and stdin = a SUMS-checked kit file (v3e: or two of them, full-render-diff.py first).

## The remote gate text (`gate_snippet`)
ONE text is used in the pre `GATES` step and again inside the SAME ssh as I3d (dev-health) or as the upgrade (ingress-nginx). Any miss prints `GATE-REMOTE STOP: <why>` and exits 3 before anything after it runs.
- **Clone checks** on every tree (dev-health: deploy-roll-24d + deploy-rollback-24d; ingress: deploy-roll-24d):
  - `remote.origin.url` == `DEPLOY_URL` (https://github.com/full-chaos/dev-health-deploy.git);
  - `git config --get-regexp '^url\.'` is empty (no insteadOf in any scope);
  - `git status --porcelain` is empty.
- **Fetch:**
  - `git fetch -q --no-tags <DEPLOY_URL> refs/heads/main` (an explicit ref, so a tag named main has no effect);
  - then `git rev-parse FETCH_HEAD` must equal `git ls-remote <DEPLOY_URL> refs/heads/main`.
- **Every code-selecting sha** (SVC_SHA + ROLLBACK_SHA; ingress TREE_SHA) must be:
  - an ancestor of the fetched main (`merge-base --is-ancestor`), AND
  - on its first-parent chain (`git rev-list --first-parent FETCH_HEAD | grep -qx <sha>`).
- **I3d ssh:** the gate text, then the live `helm history dev-health --max 1` must be `<pre LIVEREV> deployed`, then the ROLL-24d `deploy` verb.
- **Ingress upgrade ssh:** the gate text, then P0u (HEAD = TREE_SHA, `--untracked-files=no` dirty 0, the values blob == the disk blob == VALUES_BLOB, tgz sha256 = the pinned 93ea7cf2), then the live newest = `<pre LIVEREV> deployed`, then the upgrade line.

## v3f: F_POD, the real-output audit, and the render rule
**F_POD.** kubectl `-o custom-columns` pads each column with a run of spaces. v3e's F_POD wanted single spaces, so the real PODSNAP-before output (rc 0, right rows) failed its final-line check: STOP before any write. v3f: `^[a-z0-9.-]+ +[^ ]+ +[0-9,]+ +[A-Za-z]+ +[a-z0-9.-]+$` (one or more spaces between the same 5 fields). It is used by PODSNAP-before, PODSNAP-after and readback PODSNAP-now.

**The audit.** Each step's final-line regex (read from prodroll.sh itself by the test) against the real final line of that step on prod. Sources (read-only, under lanes/fcc-window-1028 unless named): the s20-a step .out files (PRODROLL-WORK-dev-health-i20-s20-a/pre), RUN-11705-r13-175427Z.log, RUN-11703s2-r12-154830Z.log, RUN-11699-ingress-161433Z.log, and lanes/fcc-11709/RUN-11709-rev425-160350Z.log (gate M, A-step, F1PIPE). The only mismatch is F_POD (PODSNAP-before and PODSNAP-after). No real step output holds a FAIL, REFUSED or HOLD word.

| step | final-line regex (v3f) | real final line (fixture) | v3e | v3f |
|---|---|---|---|---|
| I0 | `^I0 STEP=` | `I0 STEP=20 (from the inputs) SVC_SHA=d4c9131bfee56349ea4db6cf297682973` (s20a-I0.out) | y | y |
| RENDER | `^RENDER_FILE ` | `RENDER_FILE (the buffer read once; sha c919e2680f64) -> full-render-di` (s20a-RENDER.out) | y | y |
| GATES | `^GATE-REMOTE: PASS$` | `GATE-REMOTE: PASS` (s20a-GATES.out) | y | y |
| V2r-kit | `^KITREFRESH: PASS` | `KITREFRESH: PASS (both trees; verify_pins from the kit, nothing run fr` (s20a-V2r-kit.out) | y | y |
| S0 | `^loop pid [0-9]+ marker ` | `loop pid 1171239 marker logwatch-24d-1171219-1793219256` (s20a-S0.out) | y | y |
| I0s | `^START-CHECK: PASS` | `START-CHECK: PASS (revision 426 is the newest and deployed)` (s20a-I0s.out) | y | y |
| I1 | `^STATE LIVEREV=[0-9]+$` | `STATE LIVEREV=426` (s20a-I1.out) | y | y |
| ROLLBACK_REV-gate | `^GATE [A-Za-z0-9_-]+: PASS` | `GATE ROLLBACK_REV: PASS (ROLLBACK_REV = the LIVEREV 426 read live by t` (s20a-ROLLBACK_REV-gate.out) | y | y |
| I1r | `^STATE RESTARTS0=[0-9]+$` | `STATE RESTARTS0=0` (s20a-I1r.out) | y | y |
| PODSNAP-before | `^[a-z0-9.-]+ +[^ ]+ +[0-9,]+ +[A-Za-z]+ +[a-z0-9.-]+$` | `dev-health-otel-collector-7d96fb68fc-zg9m7   …ef866618-3c9c-4112-99f4-` (s20a-PODSNAP-before.out) | n | y |
| I2-collect | `^@@COLLECT OK ` | `@@COLLECT OK 2026-10-28T17:54:37Z` (r13-I2-collect.out) | y | y |
| I2-compute | `^IMG-STEP (WITHIN\|OVER)` | `IMG-STEP WITHIN: no Pending surge pod expected` (r13-I2-compute.out) | y | y |
| I3t | `^hpa ` | `hpa keda-hpa-dev-health-ops-go-sync unknown 1 2 1` (r13-I3t-topsnap.out) | y | y |
| I3g | `^HOOKGUARD PASS` | `HOOKGUARD PASS: streak-index hook Job renders` (r13-I3g-guards.out) | y | y |
| I3p | `^RENDER PATHS: PASS$` | `RENDER PATHS: PASS` (r13-I3p-render-paths.out) | y | y |
| I3d | `^pid [0-9]+ log ` | `pid 604103 log /home/ubuntu/lane-prod-k8s/roll-24d-i19.out` (r13-I3d-deploy.out) | y | y |
| I4 | `^(deploy_rc=0\|STILL-RUNNING .+)$` | `deploy_rc=0` (r13-I4-wait.out) | y | y |
| I6 | `^STAGECHECK: PASS$` | `STAGECHECK: PASS` (r13-I6-stagecheck.out) | y | y |
| I6m | `^MIGJOBLOG clickhouse action=` | `MIGJOBLOG clickhouse action=up_to_date applied=[] head=144_llm_attempt` (r13-I6m-migjoblog.out) | y | y |
| I6p | `^PGVER: PASS$` | `PGVER: PASS` (r13-I6p-pgver.out) | y | y |
| I6l | `^LIVEROWS: (PASS\|n/a)` | `LIVEROWS: PASS (1 rows read, 0 mismatched)` (r13-I6l-liverows.out) | y | y |
| PODSNAP-after | `^[a-z0-9.-]+ +[^ ]+ +[0-9,]+ +[A-Za-z]+ +[a-z0-9.-]+$` | `dev-health-otel-collector-7d96fb68fc-zg9m7   …ef866618-3c9c-4112-99f4-` (r13-PODSNAP-after.out) | n | y |
| PODSNAP-cmp | `^PODSNAP: PASS$` | `PODSNAP: PASS` (r13-PODSNAP-cmp.out) | y | y |
| I7-topsnap | `^hpa ` | `hpa keda-hpa-dev-health-ops-go-sync unknown 1 2 1` (r13-I7-topsnap.out) | y | y |
| I7-topcmp | `^TOPCMP: (PASS\|RECHECK)` (v3j: ok rc 0 or 3) | `TOPCMP: PASS (web HPA current% unchanged)` (r13-I7-topcmp.out) | y | y |
| I7-topsnap2 (v3j, only after RECHECK) | `^hpa ` | as I7-topsnap | - | - |
| I7-topcmp2 (v3j, only after RECHECK) | `^TOPCMP: PASS` | (no real run yet; tests J (b), J (c)) | - | - |
| I6s-1 | `^SCRAPE PASS` | `SCRAPE PASS (kubectl half): collector Ready, 2 auth-service pods Runni` (r12-I6s-1-scrape.out) | y | y |
| I6s-3 | `^SCRAPECHECK PASS$` | `SCRAPECHECK PASS` (r12-I6s-3-scrapecheck.out) | y | y |
| P0 | `^[0-9a-f]{64}  /home/ubuntu/lane-prod-k8s/11647/chart/ingress-nginx-4\.14\.5\.tgz$` | `93ea7cf2677577a489e14fc94d6026a1194cf2e453dc86bf43da7162109f0d59  /hom` (11699-P0.out) | y | y |
| P1 | `^cni0 inet ` | `cni0 inet 10.42.0.1/24` (11699-P1.out) | y | y |
| P2 | `^P2 compute-full-forwarded-for=\[` | `P2 compute-full-forwarded-for=[false]` (11699-P2.out) | y | y |
| P3 | `^(helm\|kubectl-patch) (Apply\|Update) keys=` | `kubectl-patch Update keys={"f:compute-full-forwarded-for":{},"f:proxy-` (11699-P3.out) | y | y |
| P4 | `^(P4 \|[a-z0-9-]+ restarts=)` | `P4 remote_addr 203.0.113.11 1` (11699-P4.out) | y | y |
| R4 | `^(P4 \|[a-z0-9-]+ restarts=)` | `P4 remote_addr 203.0.113.11 1` (11699-R4-as-P4.out) | y | y |
| UPGRADE | `^upgrade rc=0$` | `upgrade rc=0` (11699-UPGRADE.out) | y | y |
| R1-R3 | `^R3 reload lines: [0-9]+$` | `R3 reload lines: 0` (11699-R1-R3.out) | y | y |
| NEWEST | `^[0-9]+ ` | `4   …Wed Oct 28 16:17:12 2026 deployed   ingress-nginx-4.14.5 1.14.5  ` (11699-helm-history-max1.out) | y | y |
| HISTORY | `^[0-9]+ ` | `4   …Wed Oct 28 16:17:12 2026 deployed   ingress-nginx-4.14.5 1.14.5  ` (11699-helm-history.out) | y | y |
| GATE-M | `^(ABSENT\|PRESENT) /home/ubuntu/\.config/dev-health/pg-owner-rotation\.marker$` | `ABSENT /home/ubuntu/.config/dev-health/pg-owner-rotation.marker` (11709-GATE-M.out) | y | y |
| A-STEP | `^[0-9]+$` | `0` (11709-A-STEP.out) | y | y |
| F1PIPE | `^rc=0$` | `rc=0` (11709-F1PIPE.out) | y | y |

Steps with no real output yet (never run on prod), checked against the tool code (and by the fake-ssh / real-text tests):

| step | final-line regex | the final line in the code | match |
|---|---|---|---|
| I1-read | `^STATE LIVEREV=[0-9]+$` | the same helmrev verb as I1 (real: `STATE LIVEREV=426`) | y |
| PODSNAP-now | F_POD | the same kubectl custom-columns text as PODSNAP-before (real fixture) | y |
| P2-after | `^P2 compute-full-forwarded-for=\[` | the same ing_P2 text as P2 (real: `P2 compute-full-forwarded-for=[false]`) | y |
| I5 | `^APPCHECK (PASS\|WAIT)` | ROLL-24d.sh:276-277 `APPCHECK WAIT: ...` / `APPCHECK PASS: ...` | y |
| I4 / X1h-2 (rc 3 form) | `^(deploy_rc=0\|STILL-RUNNING .+)$` | ROLL-24d.sh:260 `STILL-RUNNING $2 ...` | y |
| X1h-1app | `^pid [0-9]+ log ` | ROLL-24d.sh:188 `pid $! log $LOG` (helm-rollback verb; the deploy verb :167 is the real I3d line) | y |
| I9 | `^ROLLCHECK: PASS` | ROLL-24d.sh:208 `ROLLCHECK: PASS (...)` | y |
| PREFLIGHT | `^dry-run manifest: filtered` | prodroll.sh ing_PF `dry-run manifest: filtered in memory ...` | y |
| LIVE-MANIFEST | `^live manifest: piped` | prodroll.sh ing_live `live manifest: piped ...` | y |
| ROWS | `^rows\.json sha256 ` | prodroll.sh ing_rows `rows.json sha256 ...` | y |
| PREFLIGHT-diff | `^GATE rows\.json: PASS$` | full-render-diff.py:378 `GATE <basename of --expect-rows>`; prodroll names the file rows.json (11699 real: `GATE rows-11699.json: PASS` for rows-11699.json); section B runs the real frd | y |
| ROLLBACK | `^rollback rc=0$` | prodroll.sh ing_RB `rollback rc=$r` | y |
| R4-gate | `^R4: PASS` | prodroll.sh g_R4 `R4: PASS (...)` | y |
| SECRETS / SECRETS-post | `^SECRETS: PASS$` | prodroll.sh secrets() `echo 'SECRETS: PASS'` (G2 runs the real text with a fake kubectl) | y |
| every *-gate, SECRETS-SAME | F_GATE `^GATE [A-Za-z0-9_-]+: PASS` | prodroll.sh `GATE <name>: PASS ...` (real: `GATE ROLLBACK_REV: PASS (...)`) | y |

**The fixtures.** tests/fixtures/real holds the 40 real output blocks above (one file per step) and MANIFEST.tsv (step, fixture, source log, source lines, source sha256[:12], note). Test section R5 checks each fixture's last non-blank line against the step regex of the prodroll.sh under test, and that no fixture holds a FAIL/REFUSED/HOLD word, exactly as step_rc does. Secret-free, checked before adding and again in R5: no URI with userinfo, no token or key marker (eyJ.., ghp_/gho_/ghs_/github_pat_, xox?-, AKIA.., BEGIN key, password=/token=/secret=, api key, bearer), no public IPv4 (the 2 ingress client IPs in P4 are replaced by TEST-NET-3 203.0.113.10/.11), the 2 sha12 values of the live ClickHouse URI in the F1PIPE fixture are masked to 000000000000, and every other long token is a git/sha256 hex digest, a k8s name or a path. The `bash: warning: setlocale` lines (stderr in the lead's runs) are dropped; prodroll's step files hold stdout only.

**The render rule (pm).** Any raw render made with prod values is written 0600 (umask 077) and shredded at the end of its step; the kit keeps only names/sha12 diffs. By code, the kit steps that render with prod values:
- RENDER-PATHS-24d.sh (I3p, on prod): writes 2 RAW renders (`helm template` with values.prod-secrets.yaml; Secret docs with their values included) to `$D/a.raw` and `$D/b.raw` in `mktemp -d` under `umask 077` (dir 0700, files 0600). v3e removed them with `rm -rf` only. **v3f changes line 16 only:** `trap 'shred -u $D/a.raw $D/b.raw 2>/dev/null; rm -rf $D' EXIT` (R5 runs it with real helm and a shred wrapper).
- ing_PF (ingress PREFLIGHT, on prod): `helm upgrade --dry-run=server --hide-secret > $(mktemp)` (mktemp files are 0600; --hide-secret hides Secret data). v3e `rm -f`; **v3f `shred -u "$o" "$e"`**.
- In memory only, no file: the v3e names gate (`helm template ... | python3 -I frd names`), ROLL-24d.sh okhelm and REFRESH-KIT-v2.sh okhelm (`> /dev/null`), ROLL-24d.sh hookguard (`| grep -q`).
- Not a raw render: ing_P1 writes `helm get values` (the live ingress values) and the base values to 2 mktemp files and removes them (`rm -f`).
- Kept on bigboy (0600, prodroll umask 077): WORK/pre/render.yaml (the attested RENDER_FILE through `full-render-diff filter`: Secret docs dropped, secret-named env values redacted) and the ingress dry.f.yaml / live.f.yaml (filtered the same way). These are filtered renders, not raw ones, and later steps read them (I2-compute; PREFLIGHT-diff). **Open for pm:** if "the kit keeps only names/sha12 diffs" also covers filtered renders, these 3 files must be shredded at the end of the pre phase (not done in v3f).

## v3e: named docs and kept Secrets (pm rule; dev-health only)
New inputs keys (all repeatable, no duplicates, at most 32 each):
- `REMOVED_DOC=<Kind>/<name>`, `ADDED_DOC=<Kind>/<name>`: the exact doc set that leaves (rollback tree A minus roll tree B) and enters (B minus A) the full render.
- `SECRET_KEEP=<name>`: a Secret that must stay live (type, annotation `helm.sh/resource-policy: keep`, the same key-name set before and after).
- `HOOK_SECRET=<name>`: a removed Secret that is a hook resource (not kept live by the release).
- `SECRET_KEYS=<secret>:<k1,k2,..>`: key NAMES that must exist in the live Secret.

Parse rules (REFUSED rc 2, no ssh):
- A REMOVED_DOC must be a `Secret/<x>` (the attested RENDER-PATHS r11 HOLDs on any removed non-Secret doc, so v3e does not name one), and `<x>` must be a SECRET_KEEP or a HOOK_SECRET.
- Each HOOK_SECRET must be a REMOVED_DOC `Secret/<x>`.
- Each ADDDOC must be an ADDED_DOC; each non-Secret ADDED_DOC must be an ADDDOC (so RENDER-PATHS checks its fields).

The names gate (`docs_snippet`), in the I3p ssh and again in the I3d ssh:
- stdin = full-render-diff.py, then the tool (RENDER-PATHS-24d.sh or ROLL-24d.sh), both SUMS-checked kit files. The remote text reads exactly the frd byte count (`read -N`, LC_ALL=C), writes it to a mktemp file, and checks its sha256 against the kit's; the rest of stdin is left for `bash -s`.
- Both trees are rendered with RENDER-PATHS' helm args (prod values + the prod secrets values + roll-24d-values.yaml) and piped to `full-render-diff.py names` (Kind/name lines only; no data).
- `comm` (LC_ALL=C) gives the removed and added sets; each must equal the sorted inputs set exactly (empty = empty). Any other doc added or removed: `GATE-REMOTE STOP: ...`, rc 3 = HOLD, and nothing after it in that ssh runs (no RENDER-PATHS, no deploy).
- Final line: `DOCS-GATE: PASS (removed = REMOVED_DOC, added = ADDED_DOC)`.

The Secret reads (`secret_snippet`), read-only, D6429/D6423 forms (no value is read or printed): `-o jsonpath={.type}` first; the annotation by `-o jsonpath={.metadata.annotations.helm\.sh/resource-policy}` (must be `keep`); key NAMES by `-o go-template={{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}`. Output: `SECRET-KEEP <s> type=<t> keep=yes keys=<sorted names>` and `SECRET-KEYS <s>: every named key is present`.
- pre: a step `SECRETS` (one `-n` ssh) after I3p, when SECRET_KEEP or SECRET_KEYS is set; final line `SECRETS: PASS`.
- I3d ssh: the same text after the newest-rev gate and before the names gate. So a keep annotation removed between pre and deploy STOPs before the deploy verb.
- post: `SECRETS-post` after I6l, then the local gate `GATE SECRETS-SAME: PASS`: the `SECRET-KEEP` lines (type field ignored) equal the pre ones (the Secret still exists, keep, same key-name set).

I6l: when LIVEROWS has no `Deployment/` or `StatefulSet/` row, I6l prints `LIVEROWS: n/a (0 workload rows)` locally, with no ssh, and does not fail (v3d printed a vacuous `LIVEROWS: PASS`).

## Success of a step
rc 0 (or its allowed rc) AND the tool's own final line AND no FAIL/REFUSED/HOLD word. The final lines:

| Step | Final line |
|---|---|
| GATES / I3d / UPGRADE gate part | `GATE-REMOTE: PASS` |
| V2r-kit | `KITREFRESH: PASS` |
| S0 | `loop pid <n> marker ` |
| I0s | `START-CHECK: PASS` |
| I1 | `STATE LIVEREV=<n>` |
| I1r | `STATE RESTARTS0=<n>` |
| PODSNAP save/read | a 5-field pod row |
| I2 collect | `@@COLLECT OK ` |
| I2 compute | `IMG-STEP WITHIN\|OVER` |
| topsnap | `hpa ` row |
| I3g | `HOOKGUARD PASS` |
| I3p | `RENDER PATHS: PASS` (after `DOCS-GATE: PASS` in the same ssh) |
| SECRETS / SECRETS-post | `SECRETS: PASS` |
| I3d / X1h-1app | `pid <n> log ` |
| I4 / X1h-2 | `deploy_rc=0` (rc 0) or `STILL-RUNNING ...` (rc 3) |
| I5 | `APPCHECK PASS\|WAIT` |
| I6 | `STAGECHECK: PASS` |
| I6m | `MIGJOBLOG clickhouse action=` |
| I6p | `PGVER: PASS` |
| I6l | `LIVEROWS: PASS` or `LIVEROWS: n/a (0 workload rows)` |
| I6s-1 | `SCRAPE PASS` |
| PODSNAP-cmp | `PODSNAP: PASS` |
| I7 topcmp | `TOPCMP: PASS` (rc 0) or `TOPCMP: RECHECK` (rc 3: wait 60 s, then I7-topsnap2 + I7-topcmp2 = `TOPCMP: PASS`) |
| I6s-3 | `SCRAPECHECK PASS` |
| I9 | `ROLLCHECK: PASS` |
| prodroll gates | `GATE <name>: PASS` |
| ingress P0 / P1 / P2 / P3 / P4 / R1-R3 | the tgz sha line / `cni0 inet ` / `P2 compute-full-forwarded-for=[` / an owner line / a P4 line / `R3 reload lines: <n>` |
| PREFLIGHT / LIVE / ROWS / diff | `dry-run manifest: filtered` / `live manifest: piped` / `rows.json sha256 ` / `GATE rows.json: PASS` |
| ROLLBACK / UPGRADE | `rollback rc=0` / `upgrade rc=0` |
| f1pipe GATE-M / A-STEP / F1PIPE | `ABSENT\|PRESENT <marker>` / the dirty count / `rc=0` |

## Findings -> fix -> test (v1 -> v2 -> v3)

| Ver | Finding | Fix (v3 state) | Test (v3 suite) |
|---|---|---|---|
| v1 | The inputs file could carry code | A strict KEY=VALUE reader, whitelist + one regex per key; no eval/source/`bash -c` in prodroll.sh | injection REFUSED cases; census 0 hits |
| v1 | Classifier: a new script name per roll | ONE stable path; the kit tools fed on ssh stdin | the call-form and line-1 checks |
| v2 P1-a | The inputs chose the code | The ancestor check on every code-selecting sha. The ingress tree, tgz, tgz sha, version and values path are constants. The rows are built from the EXPECT values | TREE/TGZ_SHA256 keys REFUSED; rows = acc0c437 |
| v2 P1-a | The inputs were not anchored | v2 used root `/etc/prodroll/attest/inputs.allow`. v3 (pm/acp) uses lane `ATTEST-INPUTS.txt`, appended by acp | not attested, edited after the attest, or file missing: REFUSED |
| v2 P1-b | rollback was not bound to a run | `rollback <t> <inputs> <RUN_TAG>`: this RUN_TAG's pre.pass + deploy.started, the same inputs sha, and the pre-log record == state LIVEREV | foreign or absent tag, foreign inputs, no deploy.started: REFUSED |
| v2 P1-c | PATH, ssh and the kit | Fixed PATH; kit-pinned ssh_config + known_hosts (StrictHostKeyChecking=yes); the kit SUMS check. The v2 private copy, /opt and /etc are dropped (out of scope) | ssh argv; caller-PATH fakes unused; kit edits rc 6 |
| v2 P2 | `helm get manifest` reached disk raw | Both manifests go through `full-render-diff filter` before disk | Secret + sentinel: 0 on disk |
| v2 P2 | deploy trusted a stale pre | Pre age <= 1800 s (rc 2) | stale pre REFUSED |
| v2 P3 | Usage hashing, /tmp names, child env, ssh stdin | Usage hashes only the script; mktemp + rm on prod; `env -i`; `-n` or a kit stdin | hash spy; grep; EVILVAR |
| v2 pm(a) | Pre ran a tree script | Kit-owned REFRESH-KIT-v2.sh (verify_pins verbatim from 309dadea), kept as in v2. ROLL-24d `refresh`/`prep` are never called | the verbatim diff; pre ROLL verbs = guards, helmrev, restarts |
| v3-1 | The fetch | `--no-tags refs/heads/main`; the fetched sha == `ls-remote refs/heads/main` | REAL git: a tag named main has no effect; an ls-remote mismatch STOPs |
| v3-2 | Ancestor only | First-parent AND ancestor for SVC_SHA, ROLLBACK_SHA, TREE_SHA | REAL git: a merged side commit STOPs; fake: off first-parent at deploy STOPs |
| v3-3 | The rollback target could drift | ROLLBACK_REV MANDATORY; = EXP_START_REV; = this RUN_TAG's pre LIVEREV (state + pre log); in the live helm history | missing, != EXP, != live (pre STOP), state/log/inputs mismatch REFUSED, not in history STOP |
| v3-4 | Deploy trusted local state | The I3d ssh re-runs the gate text and the live newest rev before the deploy verb | forged pre.pass/state.txt -> STOP on the live mismatch, no deploy; REAL git: url.insteadOf, origin, untracked STOP |
| v3-5 | Hash and parse could differ | Read once into one buffer; hash and parse that buffer; the record copy = the buffer | NUL REFUSED; record copy = file bytes |
| v3-6 | Attest anchor | ATTEST-INPUTS.txt (lane constant, copy override for tests) | see the v2 P1-a row |
| v3d D6436 (pm) | The attest was acp-only, and a 3-field line had no checker; an author could attest their own inputs | 4-field lines `<sha256> <roll> <UTC> <checker>`; the inputs key AUTHOR (required); a matching line counts only with exactly 4 fields, a valid checker token and checker != AUTHOR; the refusal text says "a peer lead appends" | RED on v3c -> GREEN: a 3-field line, a 5-field line, checker == AUTHOR, a bad checker token, all lines by the author, a missing AUTHOR and a bad AUTHOR give REFUSED rc 2 with no ssh; a peer checker passes; mixed lines with one peer checker pass |
| v3e (pm, 11712) | v3d could not see removed Secret docs (RENDER-PATHS drops Secret docs; `names` was not run), so a doc could leave the release unseen; I6l printed a vacuous PASS on 0 workload rows | REMOVED_DOC / ADDED_DOC names gate in the I3p and I3d ssh; SECRET_KEEP / HOOK_SECRET / SECRET_KEYS reads in pre, the I3d ssh and post; parse rules; I6l n/a | RED on v3d -> GREEN: a removed doc not listed, a listed doc not removed, an added doc not listed: HOLD (no RENDER-PATHS PASS, no deploy); keep absent in pre: STOP before I3d; keep absent at I3d: STOP, no deploy verb; the Secret gone in post: STOP; a missing key name: STOP; a REMOVED_DOC Secret without SECRET_KEEP or HOOK_SECRET, a HOOK_SECRET not removed, a non-Secret REMOVED_DOC, a lower-case kind, a bad SECRET_KEYS, a duplicate, an ADDDOC not in ADDED_DOC: REFUSED rc 2; G2: the I3p remote text run with real helm + the kit frd on toy charts (happy, 4th removed, listed-not-removed, added, truncated frd: rc 3), the Secret text with a fake kubectl (the exact jsonpath/go-template args; nokeep, nokey, gone: rc 3) |
| v3f (s20-a STOP) | F_POD wanted single spaces; real kubectl custom-columns pads with runs of spaces, so the real PODSNAP-before (rc 0) STOPPED the first v3e pre; the regexes were tested only on hand-written lines; RENDER-PATHS and ing_PF removed raw renders with rm, not shred | F_POD ` +` between fields; 40 real-output fixtures + MANIFEST.tsv, every final-line regex tested on them; RENDER-PATHS line 16 and ing_PF use shred -u | RED on v3e -> GREEN: the real PODSNAP-before and PODSNAP-after fixtures fail on v3e and pass on v3f; a pre with the real padded rows passes; the dry-run ssh shreds; RENDER-PATHS shreds a.raw + b.raw (real helm, shred wrapper) |
| v3j (s30-a, s36-a STOPs; pm) | I7-topcmp gated the web HPA on ONE post sample even when web was not rolled; user traffic (web 3% -> 20%, 4% one minute later) STOPPED 2 good rolls | Gate only the HPAs of PODSNAP_TARGETS (NOTE for the others); a move on sample 1 = RECHECK (rc 3), wait 60 s, sample 2 (I7-topcmp2, final) decides | J (a) web not rolled moves: PASS + NOTE; J (b) rolled, back in range on sample 2: PASS; J (c) moves twice: STOP; J (d) unchanged: no sample 2; MUTANT (web always gated): J (a) FAIL |
| v3-7 | Self-check | PINNED_SELF_SHA256 + the kit SUMS | an edited comment or pin line: rc 6 |
| v3b P1-1 | v3's `sed '/^PINNED_SELF_SHA256=/d'` stripped ANY line with that prefix, so `PINNED_SELF_SHA256=<pin>; <code>` passed and ran (v3 DESIGN item 8 was false) | The self-check runs at the top, before the pin line: exactly 1 prefix line; that line is exactly `=<64 hex>`; the hash deletes that line BY NUMBER | RED on v3 -> GREEN: the trojan line gives rc 6 and TROJAN-RAN prints 0 times; a byte-equal second pin line gives rc 6; a second prefix line gives rc 6; control: an edited copy re-pinned on its one exact line passes |
| v3b P1-2 | A symlinked install (the file, or a dir in its path) became copy mode: lane ATTEST + PRODROLL_TEST_PATH with a real ssh | Prod mode refuses rc 6 when `$0` names PROD_SELF but resolves elsewhere, or when any component of the prod path or the kit dir is a symlink. Copy mode refuses rc 6 unless PRODROLL_TEST_PATH is valid and holds the resolved ssh | RED on v3 -> GREEN: a symlinked file, or a symlinked parent dir, gives rc 6 and never mode=copy; copy mode without a test path, with a path without ssh, or with an invalid path gives rc 6 before any ssh; control: the genuine prod layout is mode=prod |
| v3b P3(a) | `helm ... \| grep \| head -12; echo rc=${PIPESTATUS[0]}`: a long helm output gave SIGPIPE rc 141, a false STOP after a good roll | `o=$(helm ... 2>&1); r=$?`, then print the first 12 lines of `$o`, then `upgrade rc=$r` / `rollback rc=$r` | RED on v3 -> GREEN: the exact remote texts from the ssh log, run with a fake helm that prints 200000 lines and exits 0, print `rc=0` (v3: `rc=141`), 12 lines shown |
| v3c P2-1 (acp on v3b) | The pin line could move (a line added above it, re-pinned) and line 1 was not checked | The pin must be line 34 exactly, and line 1 == `#!/bin/bash -p`; else rc 6 | RED on v3b -> GREEN: the pin moved to line 35 (re-pinned) gives rc 6; line 1 `#!/bin/bash` (re-pinned) gives rc 6 |
| v3c P2-2 (acp on v3b) | The copy gate accepted PRODROLL_TEST_PATH=/usr/bin or /bin (the real ssh) | The test path must be under lane-scratch (no `..`); its ssh must be what PATH resolves and must not be `-ef /usr/bin/ssh`; DESIGN states exactly what holds | RED on v3b -> GREEN: /usr/bin, /bin, a lane-scratch link to /usr/bin/ssh, a fake under /tmp, and a `..` path each give rc 6 with no ssh; control: the fake under lane-scratch passes the gate |
| v3b P3(b) | EXPECT_NEWEST_REV was only `>` EXP_START_REV | It must be exactly EXP_START_REV + 1 (dev-health and ingress) | RED on v3 -> GREEN: 427 vs 425 and 5 vs 3: REFUSED rc 2, no ssh |
| v3 (rev. brief 6) | rc 0 was enough | rc + the final PASS line (table above) | guards without HOOKGUARD PASS, stagecheck without STAGECHECK: PASS: STOP |
| v3 (rev. brief 7) | Ingress P0u and the upgrade were 2 ssh | One ssh: gates + P0u + newest + upgrade | 1 ssh in the upgrade phase; P0u fail -> no upgrade |

## Unchanged from v2
- The step order of each subcommand, the phase markers, the `wait` phase and the bounded waits.
- The 8 r11 tool files (byte-equal; SUMS abb533ff), except RENDER-PATHS-24d.sh line 16 in v3f (the shred trap); f1pipe-11709.sh (8c2e9585); full-render-diff.py (b19f2889); REFRESH-KIT-v2.sh (d004c43f).
- The 3 example forms (`PRODROLL_INPUTS=3`).
- Lead steps outside the kit: I6s-2, I6e, F12/R0, the 11709 run, 11712.

## acp's other P3 notes (records; not changed in v3b)
- **The `<roll>` field of ATTEST-INPUTS.txt is not bound.** prodroll matches only the first field (the inputs sha256). The roll name and the UTC are for the reader. One sha attests one exact inputs file, and that file names its TARGET, RUN_TAG and STEP.
- **The pre phase writes on the prod host.** These writes are expected, and none of them is a helm upgrade or a cluster write:
  - git fetch (FETCH_HEAD and objects) in deploy-roll-24d;
  - REFRESH-KIT checkouts + submodule update + `helm dependency build` (chart/charts/, ignored) in both trees;
  - LOGWATCH start (a loop pid file and logs in ~/lane-prod-k8s);
  - the PODSNAP before file (noclobber);
  - the guards verb (a checkout of SVC_SHA; mkrv writes ~/lane-prod-k8s/roll-24d-values.yaml);
  - the RENDER-PATHS mktemp dir.
- **SERIES_FILE is not attested by content.** The lead writes it after the roll (I6s-2), so its sha cannot be in the inputs. scrapecheck reads it by path, prints its sha256 in the run log, and is read-only.
- **The f1pipe gates are separate ssh calls.** Gate M and the A-step run in ssh calls before the F1PIPE run, so a change between them is not seen by those gates. f1pipe-11709.sh re-checks the rotation marker itself (its P0), but not the A-step tree. A same-uid change is out of scope.

## Open (for acp / fcc)
0. **AUTHOR and the checker are self-declared names (acp P3 on v3d).** Both are text in files that every lead writes with the same uid (the honor system). The checker != AUTHOR rule stops an accidental self-check, not a dishonest one; this fits pm's not-a-sandbox scope.
1. **Pinned URL.** DEPLOY_URL comes from ROLL-24d.sh:145 and the bigboy origin; it is not read on prod (this lane has no prod access). The first pre GATES shows it: a different origin STOPs.
2. **`url.*` keys.** The check reads every git config scope. If the prod user's global config has an insteadOf (for example, for a GitHub credential), every run STOPs (fail closed). fcc reads `git config --show-origin --get-regexp '^url\.'` on prod once.
3. **`git status --porcelain` on the prod trees.** An untracked build artifact, or a submodule with untracked content, STOPs the run. chart/charts/ is in .gitignore. If prod shows an artifact, fcc names it and acp rules on it. There is no allow-list in v3.
4. **Main only.** A roll uses only first-parent commits of main (no PR head, no side commit of a merge).
5. **Ingress scope.** The ingress subcommand is fixed to chart 4.14.5 and the 3-key ConfigMap form.
