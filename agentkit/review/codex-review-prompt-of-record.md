# Codex PR-round prompt of record — 2026-09-09 20:25Z (chris: "3 rounds is already too much because you're not giving it the proper prompt")

Owned by team-lead. Lanes fill ONLY the bracketed fields. Nothing else is added: no round history, no
"context not focus" sections, no disclosures, no hints, no "what I want most". Prior findings live in
the PR body's TEST-EVIDENCE/RISK-NOTES and the reviewer reads the diff and the body, not a narrative.
A lane sends team-lead the prompt's sha256 with the slot request; team-lead reads the prompt before granting.

---- PROMPT (copy verbatim, fill brackets) ----

Adversarial review of PR #[N] at tip [full sha] against origin/main [full sha].

What this change is trying to accomplish, and for whom:
[two to six sentences from the ticket and the PR body -- the feature or change, the user or operator it
serves, and what "working" means to them, with full system context across both repositories, the design,
and the engine. No round history, no hints, no list of paths or seams to check.]

Diff: `git diff [main sha]...[tip sha]` — [F] files, +[A]/-[D].

The PR body (## TEST-EVIDENCE, ## RISK-NOTES) is at .codex-review-context.md in this worktree. Every
claim in it is unverified until you execute it.

Find the ways this change fails to accomplish the above, or breaks something that worked, and prove each
one by running it: a test case, a command, a bring-up, a request -- executed, with its output. Use the
change the way its user would, from scratch, and go wherever the change can reach; nothing reachable is
out of scope because it is not named here. A claim without executed evidence, a test that cannot fail,
and a guard that checks text instead of behaviour are findings too. Report each finding with `path:line`,
severity P1–P3, and the executed reproduction.

Question, answered verbatim before the verdict: what does this change make observable, and what
regression in it would be invisible at Info?

Final line, alone, exactly one of: CLEAN | NOT CLEAN | BLOCK | REQUEST CHANGES

---- END ----

Rules: diff counts are generated from `git diff --numstat`, never typed. Do not enumerate paths or seams in the prompt (dictation 1625). The launcher writes the current PR body
(the text the one body edit will carry) to `<lane worktree>/.codex-review-context.md` — gitignored, UNTRACKED — and records
its sha256 in the launch log; wrapper v4.8.17 line 1896 copies it into the review worktree. It is NOT committed and never
ships (a body file must not land in the tree). No CHAOS- strings in the PROMPT. Repo rule for the body: acr bodies carry 0
CHAOS- strings (Trap #108 auto-close); dev-health-go/ops bodies carry `Ticket: CHAOS-<n>` for the ONE ticket delivered.

**AMENDMENT, 2026-09-09 22:0xZ**: the installed wrapper (`_shared/codex-review.sh.v4.8.17-676eace3d73d`, the latest version in `_shared`) copies only `prompt.md` + `.codex-review-context.md` into the review worktree — it has NO `.review/pr-body.md` staging step. The prompt line above and the rule above are corrected to match what the wrapper actually does, not what an earlier draft of this file assumed. Until a future wrapper version adds a `.review/pr-body.md` step, every lane puts the PR body verbatim in `.codex-review-context.md`, and the prompt's path line must say `.codex-review-context.md`, never `.review/pr-body.md`.

Amendment 2026-09-09 22:0xZ (team-lead): `PR #[N]` — open the PR FIRST (draft is fine) and round on the pushed tip with the real
number; a round never precedes its PR. "No CHAOS- strings" binds the PROMPT only; `.codex-review-context.md` IS the real PR body and
carries its own ticket reference (ONLY the ticket it delivers, Trap #108).

Amendment 2026-09-09 22:12Z (CF): the launcher ASSERTS `<lane worktree>/.codex-review-context.md` exists and logs its sha256 BEFORE exec — the wrapper's copy is a silent no-op on a missing file, and the prompt would then cite a body the reviewer never received.

Amendment 2026-09-10 03:2xZ (lane-review-perms, v4.8.18): docker available to the reviewer via the codex-review permissions profile; container-backed tests are the reviewer's to run; DSNs via env.

Amendment 2026-09-10 03:27Z (CF): wrapper of record is now `_shared/codex-review.sh.v4.8.18-287d50dfdabe` (sha256 287d50dfdabe4a03ec4f2cd895b627b97e65190addb94443f1ef85dc21dcc4fb; CF read CLEAN; v4.8.17 RETIRED). The context copy loop is at line 2007. Default `CODEX_REVIEW_PERMS=legacy` = v4.8.17 behaviour (network closed, `-s workspace-write` on the cmdline). CF rounds run legacy unless the round needs docker; a `codex-review`-mode round is named in the grant, proves itself by the wrapper's logged `perms: mode=codex-review codex_home=… profile_sha=…` line (there is no `-s` flag in that mode), and has open network egress (chris Option A). Rounds launched before this amendment finish on v4.8.17.

Amendment 2026-09-10 05:2xZ (team-lead): in `codex-review` (docker) mode the reviewer MUST NOT run `ci/local_validate.sh` or any
script whose defaults target the shared compose project (`CH_CONTAINER=dev-health-clickhouse-1`, `dev-health-postgres-1`) — the
gate is the LANE's to run and cite. Incident: the #2426 r1 reviewer took `/tmp/dev-health-ops-local-validate.dev-health-clickhouse-1.lock`
at 05:12Z (no writes reached the live ClickHouse — verified from `system.query_log`, all mutations in that window came from compose
workers 172.19.0.x). Until the wrapper (v4.8.19) exports lane-scoped `CH_CONTAINER`/`PG_CONTAINER` into the round env and denies the
compose names, lanes launching codex-review mode add ONE line to `.codex-review-context.md`: "Do not run ci/local_validate.sh; the
gate result is cited above; run package tests (testcontainers start their own containers)."

Amendment 2026-09-10 15:5xZ (team-lead, chris: "Is the prompt still too narrow on requested changes? Again, it should catch this the first two rounds."): the Method paragraph now opens with EXECUTE-THE-CLAIM and ENUMERATE-THE-SURFACE. Cause: #2429 went three rounds finding one class ("a fresh compose up does not actually run") and #2422 nine rounds sampling gqlgen config knobs one per round -- the old Method was code-review-shaped (tests, pins, mutations) and never asked for the deliverable to be executed from scratch or for the input surface to be enumerated. Binding on the BODY too: a lane's TEST-EVIDENCE carries the executed end-to-end claim and the enumerated surface BEFORE r1, or the TELL is refused.

Amendment 2026-09-10 19:1xZ (team-lead, chris: "The prompt is still not adhering to my rule if we keep hitting the same walls. Or the agent needs better instructions."): three PRs today each spent three rounds on ONE class — a guard/validator/certifier the change added handled a subset of its input domain, and each round found one more untreated shape (presence → type → nested → integrality → nil; reconciled-flag → aggregate path → container type). The Method paragraph's mutation sentence is replaced by:
"construct mutations against every guard, pin and instrument the change adds or modifies and show which test kills each one; for EVERY guard, validator, certifier or parser the change adds or modifies, enumerate its whole input domain — each field × {absent, null, zero, empty container, wrong container type, wrong scalar type, fractional where integral, out of vocabulary, boundary and boundary±1, duplicate, and the canonical value} — execute every cell in ONE pass and report every cell the change does not refuse or accept as its contract says; sweep every caller of every touched function."
Binding on the BODY (lane side, same rule as EXECUTE-THE-CLAIM): TEST-EVIDENCE carries that input-domain table, executed, BEFORE r1, or the TELL is refused. A round that reports a cell the lane's own table already contains is the lane's failure; a round that reports a cell the table does not contain is the table's failure — either way the next fix covers the whole domain, never the reported cell.

Amendment 2026-09-10 23:5xZ (team-lead, chris on #2436 reaching round 4: "the prompt needs to be adjusted for you, as I've said a million times, if we're hitting round 4"): #2436 r3 and #2429 r5 landed the same evening with three P1s each, none new to the code, all new to the METHOD: (1) an encoding fix applied to the password component only -- the database name was still raw (`#` activated the wrong database): a fix for one field of a class was never swept across its siblings; (2) `--set-json enabled=null` bypassed a new boolean type -- the body LISTED the null cell and never executed it; (3) a new test passed in the lane's venv and failed under the documented `uv sync --no-install-project` setup; (4) `POSTGRES_DB` overridden for provisioning while postgres itself hardcodes `postgres`, and a digest image override colliding with `pull_policy: build` -- pairwise knob interactions no per-field table sees; (5) billing's `/ready` 404 accepted as "inherited". The Method paragraph now carries five sentences for exactly these: CLASS-SWEEP across siblings, PAIRWISE knob × consumer cells, PRE-EXISTING-INSIDE-THE-SURFACE is the change's failure, FRESH-SETUP suites, and a listed cell without command+output is UNEXECUTED. Binding on the BODY (lane side): every domain cell shows its command and output; every guard/encoding fix names the sibling set it was swept across; the pairwise table exists for every config-bearing change; the suite line quotes the fresh-setup command. A TELL whose body lacks any of the four is refused. sha256 of this file after this amendment is whatever `sha256sum` says at fill time -- hash it, never quote it.

Amendment 2026-09-11 01:1xZ (team-lead): #2437 r3 found the class-sweep's failure mode — the body listed `/buildinfo` under "siblings checked, no fix needed" by reasoning; the executed cell (a `0xFF` commit byte, a case-shadowed `MODIFIED` key) enabled a row. One clause added to the class-sweep sentence: a sibling dismissed by argument instead of an executed cell is an unswept sibling. Binding on the body: every sibling row carries its command and output, same as a domain cell.

Amendment 2026-09-11 01:1xZ (chris: "Just run them with the widened prompt. We're being so specific it's allowing agents to go through."): one framing sentence opens the Method -- the lists are examples of the standard, never its boundary. No further enumerations are added to this prompt for specific finding classes; a recurrence is answered by widening, not by naming the case.

REWRITE 2026-09-11 01:1xZ (chris, verbatim: "Just run them with the widened prompt. We're being so specific it's allowing agents to go through." and "Like, I've literally said: 'Pass it the feature or change context of what's trying to be accomplished, then ask it to find issues and prove they are with running test cases' (paraphrased) that would eliminate so much back and forth."): the PROMPT block above is REPLACED by that shape -- intent first, then "find the ways it fails and prove each by running it". The enumerated Method paragraph (execute-the-claim, enumerate-the-surface, the per-field domain table, class sweep, pairwise, fresh setup) is RETIRED from the prompt; it remains the LANE'S OWN standard for the body (rules 18/21 still bind the body's TEST-EVIDENCE), never a list handed to the reviewer. Every amendment paragraph below the END marker is history. Lanes fill the new "What this change is trying to accomplish" bracket from the ticket + PR body, nothing else.

Amendment 2026-09-14 (dictation1696): wrapper of record is now `_shared/codex-review.sh.v4.8.19-39fd6e65aeb6`, sha256 `39fd6e65aeb65e2d1c6072b6b8859cb61165b3ed625ac81b746a119b5d1c821e`. Library-only warm builds fall back to `go build ./...` (and the integration-tag twin). Exact library, invalid-build, and main-package controls passed. Earlier versions are preserved. Model preference for resumed work: Luna max by default; orchestrator may choose another model/effort for difficulty, per Chris.

Amendment 2026-09-14 13:02 UTC: applied the already-binding dictation1625 to the prompt block and its fill rules. The obsolete file enumeration is removed. The intent bracket requires full system context across both repositories, the design and the engine, with no path/seam checklist. This corrects the template to Chris's existing ruling; it adds no review round or gate. The wrapper is unchanged. Hash this file at fill time.
