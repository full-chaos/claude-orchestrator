# GWC vet checklist (D2879, 2026-09-28T15:2xZ)

Run every line below on every tip vetted, no judgement call on scope. State
each line's result (pass/fail/n-a with reason) in the VET OK / hold message.

1. **Merge-tree vs current main** clean (`git merge-tree --write-tree HEAD origin/main`, no conflict markers).
2. **Build/vet/gofmt** clean for every touched Go package (`go build ./...`, `go vet`, `gofmt -l`).
3. **Python lint** on every touched Python file: `ruff format --check` + `ruff check`. **Plus `.venv/bin/mypy` on every touched Python file (D3116-class, 2026-09-29): #3394's test-only rewrite passed ruff + pytest and failed hosted typecheck-mypy (unused `type: ignore` + attr error).**
4. **The touched packages' own tests** green, run fresh (not cached).
5. **tests/tooling registry/shard contract suite** (`test_venue_oracle_registry.py` + `test_venue_oracle_shards.py`, or the equivalent for the class of test/oracle added) whenever a test or oracle is added anywhere in the diff -- run it even if the new test lives in an unrelated-looking package. **Run the WHOLE `tests/tooling` directory (not the two files) whenever the diff adds a `_test.go`, especially a `//go:build integration` file in a package that had none, or any generated code (2026-09-29): #3385 passed my two-file run and failed hosted on `test_go_integration_sharding.py` x4; on any GraphQL-generated-code diff also run `go run ./cmd/gqlgen-guard check-drift` (it failed hosted on generated-file provenance).**
6. **Full string-leaf scan** (source capture vs repo fixture, PLUS all prose files: README.md, PR body) whenever a fixture or captured/real data is added -- script it (extract every string leaf, intersect, review by field name), never a manual spot-check or a grep for only the values named in a commit message.
7. **PR body headings**: `## TEST-EVIDENCE` and `## RISK-NOTES` present, literal, on any PR this vet leads to opening.
8. **No values in text**: this vet's own report to lead never quotes a real captured value, credential, or PII -- counts and field names only.
9. **R471**: no `git stash` used anywhere during this vet (use `git show <rev>:<path>` or a scratch detached worktree for any revert-test).
10. **GraphQL operation registry/manifest parity** (D2896, 2026-09-28): whenever a diff registers or removes a GraphQL operation on cmd/query-api's route table, run `go test ./internal/goapiproof/...` (registered_set_test.go's TestOperationSpecsCoverExactlyWhatQueryAPIRegisters + TestTheHandWrittenRegisteredListMatchesTheRouteTable) AND the web wire-parity manifest check (`graphql-wire-parity` job / `scripts/graphql-wire-parity.ts`) fresh, even when the touched-package tests in item 4 already passed. A round reviewer sees the diff, not these hand-written registries -- #3376's r1 CLEAN verdict missed exactly this (home added to the route table, absent from both registries), caught only by hosted CI.
11. **All hosted checks, not the tail**: read every row of `gh pr view N --json statusCheckRollup`, never `gh pr checks N | tail -N` -- a CLEAN round verdict or a short glance is not evidence hosted CI is green.
12. **Whole tests/tooling suite, no selection** (D2922, 2026-09-28): a PR that touches any file under `ci/`, `scripts/`, or `tests/tooling` runs the ENTIRE `tests/tooling` suite in the vet, one command (`pytest tests/tooling/`) -- never a grep for guard/pin tests named after the touched file, and never a hand-picked subset. #3362's 660a825f5 passed a targeted run and still broke two pre-existing guards elsewhere in that same directory that a grep-for-filename approach would not have found by name.
13. **Auth-path fail-open sweep** (D2921, 2026-09-28): on any PR touching an authorization/authentication check, grep the diff for every store/lookup error path feeding that check and name each one explicitly -- confirm it refuses the request on error, never defaults to allow. A store error on an auth lookup is a fail-open bug if it is not asserted closed.
14. **Verdict validity: hand-built schema is UNMEASURED, not a finding** (D2999, 2026-09-28): before accepting any data-layer P1, check the round's own verification section for a migration-chain failure (e.g. `settings_mismatch` during `dho migrate clickhouse upgrade`) or any hand-written/hand-built table DDL substituted for the real one. A reviewer who could not complete the real migrate chain and built a substitute schema instead is reporting against an UNMEASURED environment -- the finding is void, not confirmed, until re-run against the real chain. Source: #3374 r1's "org sync wipes teams" P1 came from a bare 002-migration teams shape; migration 061 already keys the real table by (org_id, id), fixing exactly this.

15. **Retarget stacked PRs before merging a base** (D3010, 2026-09-28): before merging any PR
that is the base of another open PR, run `gh pr edit <stacked#> --base main` for every PR
stacked on it, THEN merge the base, THEN verify each retargeted PR is still `OPEN`
(`gh pr view <#> --json state`). GitHub auto-closes a stacked PR when its base branch is
deleted at merge, which auto-cancels the linked Linear ticket, and GitHub refuses to reopen
it -- a replacement PR must be opened from scratch. Real case: #3362 merged and deleted its
branch; #3369 (stacked, CHAOS-7023) auto-closed, ticket auto-canceled, #3384 opened as the
replacement.

16. **No hand-written wire-parity manifest entries (CHAOS-4696) -- but registration-order is
ops-first, not a 3-PR split** (D3012, 2026-09-28, supersedes D3011 -- CHAOS-6154/web #946
already removed the CHAOS-6089 tolerance D3011 assumed, so D3011's split-the-registration-out
ordering was wrong). Correct order per chris's own RISK-NOTES: ops registers first; the web
half (pin bump + real query + manifest entry) merges in the SAME SESSION right behind it; the
ops `graphql-wire-parity` job is red (non-required) only in the gap between the two merges --
never left red across a session close. Mechanics: (a) confirm `graphql-wire-parity` is NOT a
required/blocking check before merging ops with it red (`mergeStateStatus` reads UNSTABLE, not
BLOCKED, and/or no branch protection lists it); (b) the moment the paired web PR is green,
merge it immediately, don't hold it; (c) if the merging ops PR is the base of a stacked PR,
retarget the stacked one first (item 15). Live pairings (2026-09-28): #3376(home, merged
87d4989fa)/#3382(home r2)->CHAOS-7064/web; CHAOS-7065(recommendations)->#962;
CHAOS-7066(workItemTeamAttributions)->#961.

17. **Hardened-client ports enumerate the source's hardening flags before r1** (D3016,
2026-09-28): a PR that ports a hardened HTTP/network client (Python httpx or similar) to Go
must list every hardening property of the SOURCE client -- trust_env, follow_redirects,
timeout, SSRF/allowlist gate, retry/backoff -- with a file:line citation for each, in the PR
body's RISK-NOTES, BEFORE the first review round. Vet this presence directly; a missing or
thin table is itself a finding, not a style nit. Source: #3371 (CHAOS-6976) took 3 rounds,
each landing a real P1/P3 (stale cert after credential rotation, ambient HTTPS_PROXY honored
when Python sets trust_env=False, oracle asserting roles only not content) -- the thin PR
body, not the round process, was the actual defect; building the table after the fact (D3016)
also caught a 4th unremarked divergence (Go timeout 30s vs Python's real 60.0s).

18. **Rebase-check against CURRENT origin/main before every merge; re-vet integration tags on
shared-signature PRs** (D3034, 2026-09-28): a merge-tree check against a stale local
origin/main is not enough -- `git fetch origin` immediately before the final merge-tree, and
if the PR touches a widely-called function's signature (or the PR's own merge-tree/CI shows
an unrelated static/vet failure), run `go vet -tags=integration ./...` (or the affected
package) against the PR merged with CURRENT origin/main, not just the PR's own branch in
isolation. Real case: #3376 added a newQueryHandler call site while #3380 (merged minutes
apart, both hosted-CI-tested against PRE-merge main) changed newQueryHandler's return
signature -- neither PR's own CI saw the other's change, so the combination broke main's
`go vet -tags=integration` (one call site never updated to the new 4-value return) and
nothing caught it until it broke every subsequent PR's CI. Semantic (signature) conflicts
across concurrently-landing PRs are invisible to git's textual merge and to each PR's own
isolated CI -- only a re-vet against current main after both land would have caught it.

Standing rule: every relay that ends in a push names "send me the sha, wait
for VET OK" explicitly -- never instruct a direct push, even for a
mechanical/tooling/no-round class fix-forward (D2876).

19. **A tip under VET request is frozen until the scribe answers** (D3088, 2026-09-28): a lane that rebases, amends or pushes a tip while it is being vetted voids the run in flight. Send the sha, wait for VET OK/HOLD; if a rebase is unavoidable, say so and name the new tip, and the vet restarts on it. Instance: gwc-cut-hardening moved #3388 480253cf5 -> 46b5b1bbb mid-vet (main moved under it); range-diff proved content equal, but the integration run had to be re-anchored.

20. **The round's context body equals the live PR body at launch; byte-equality checked at merge** (D3092, 2026-09-28): `.codex-review-context.md` must be the PR body the reviewer's verdict will be read against. At merge, compare `gh pr view N --json body -q .body` with the round's context file (sha256 or `cmp`); a mismatch means the verdict reviewed a different text than the one that merges — make the ONE body edit to match first, or the round does not count. Instance: #3388 r1 (pid 1052940) launched on a lane-rewritten context body; #3388 makes one body edit before merge.

21. **A REST -> GraphQL move carries every parameter the REST call sent** (D3154, 2026-09-29): before VET OK on a PR that moves a web read from a REST route to a GraphQL field, diff the REST handler's query/filter contract (every query-string parameter and body filter the web call sends) against the GraphQL field's arguments and input types; a REST parameter with no GraphQL argument is a silent default (the server falls back) and a finding. Instance: web #968 r1 P1 — the home GraphQL field had no time-window argument, so a 90-day ask was answered for the default 14 days across ten call sites. My web vet (schema byte-equal to ops, wire-parity 56/56, vitest) could not see it: it checked the contract against itself, not against the REST call it replaced.

22. **A deleted Python surface (field, route, resolver, module) runs the top-level contract tests** (2026-09-29): #3382 deleted Python's `home` field; my vet ran `tests/api/graphql`, whole `tests/tooling` and the Go suites and still missed `tests/test_endpoint_profiles_contract.py` + `ci/check_endpoint_profiles.py` (a row for the deleted field stayed in `contracts/auth/v1/endpoint-profiles.ops.json`) — hosted `test`/`test-matrix 3.14/2` caught it. On any Python deletion run `ci/check_endpoint_profiles.py` and `pytest tests/test_*.py -k 'endpoint or contract or profile or discovery or graphql or auth'`, and `rg` the deleted name across `contracts/`, `ci/`, `docs/` for stale rows.

23. **A PR that adds a migration or any Alembic/Python-derived Go table runs the live-Python oracles verb** (2026-09-29): #3389 added Alembic 0145 and my vet passed, but hosted `go-quality-leg (oracles)` failed `TestSchemaRevisionsMatchLivePythonAlembic` (internal/api/health/schema_revisions.go one revision short). On any diff touching `src/dev_health_ops/alembic/versions/`, `pgmigrate` goldens, or a `*_live_python_oracle_test.go`, run `ci/check_go.sh live-python-oracles` (or every affected oracle with DEV_HEALTH_LIVE_PYTHON_ORACLES=1, venv PATH, PYTHONPATH=<wt>/src, and the proof dir) — the integration-tagged suites do not cover them.

24. **Any PR that adds an Alembic revision regenerates the health schema-revision pin** (D3229, 2026-09-29; the lead called it "item 22" — that number was already taken, so it is 24 here; item 23 has the verb to run): `internal/api/health/schema_revisions.go` must list the new revision (`TestSchemaRevisionsMatchLivePythonAlembic`), together with the pgmigrate goldens and `sql/`+`baseline/history.json`. Instance: #3389 added 0145 (go_api_proof_orgs) without it and the hosted `go-quality-leg (oracles)` leg went red.

25. **A migration PR runs the WHOLE Python suite that mentions revisions/org-deletion, and the storage shard of every package it touches** (2026-09-29): #3389 (Alembic 0145) passed my pgmigrate/postgres integration and oracle runs and still failed hosted on (a) `tests/test_worker_operator_audit_migration.py` (pins head '0144') and (b) `TestOrgsDeleteMatchesTheFrozenPythonOutput` (new org_id table missing from the frozen Python org-deletion rows). On any diff adding a revision: `rg -l "0144|head" tests` style search for revision pins, run `pytest tests/test_*migration*.py tests/test_*org_delet*.py`, and run the affected storage shards (`ci/check_go.sh` integration shard verb for internal/api/... orgdelete) — never rely on a named subset.

26. **A Go resolver's error/empty behaviour matches Python's per stage, proven by an executed golden, never by assumption in either direction** (D3249 corrected by D3251, 2026-09-29; the lead called it "item 25" — that number was taken, so it is 26 here): for every stage of a ported resolver (input decode, window/date computation, query, row mapping, stream) state what Python does on failure (raise -> GraphQL error, catch -> skip the row, swallow -> empty) and prove Go does the same with a live-Python oracle case (injected error, overflow, mid-stream error) plus mutants. Neither "Go must never return empty on error" nor "Go may swallow like Python" is a rule by itself; the executed golden decides. grep the diff for `return nil, nil` and empty-slice-on-err patterns and make each match cite its Python counterpart. Instance: #3385 r1 (null evidence became 0), r2 (mid-stream error returned a partial list), r3 (oversized window: Python OverflowError, Go returned []).

27. **A vet runs read-only against the lane's worktree** (D3308, 2026-09-29): never write into a lane's worktree — no mutation edits, no formatter without `--check`/`--diff`, no `git checkout`/`stash`. Run mutants, formatters and anything that edits in a detached scratch worktree (`git worktree add --detach <scratch> <tip>`), remove it afterwards. If a lane worktree was touched, restore by content (`git diff` against the lane's committed tip must be empty apart from the lane's own uncommitted work), and tell the lane exactly which files changed. Instance: #3406 vet mutated three files in gwc-cut-hardening-7162 while the lane had uncommitted edits there; restores were by digest of a copy taken seconds earlier, so a lane save in that window could have been lost.

28. **A go-served ledger change runs the goapiproof INTEGRATION package, not only its unit tests** (2026-09-29): #3410 (ledger enable_limit on 17 ops) passed my goapiproof/graph/goapicli unit runs and the lane's routing-pkg integration run, then hosted CI failed `internal/goapiproof` `TestEnableDryRunRunsTheGateAndWritesNothing` (its "unproven half" operation had just become limited, so `Enable` returned nil). Run `go test -tags=integration -timeout 40m ./internal/goapiproof/` (~10 min) in the scratch worktree for any PR that edits `goserved_ledger.json`, a proof gate, or an operation named by a routing integration test; grep the integration tests for every operation whose ledger state changes.

29. **The PR body states the contract the reviewer will attack — before ANY r1 launch** (D3364, chris 2026-09-29: "3 rounds = the prompt/body was too narrow, again"): a body without this section is NOT VET OK for the round. Verb/CLI: inputs, preflight scope (what state it checks), atomicity/transaction scope, outputs + audit. Renderer/checker/config tool: exact inputs, what may appear in the output, what is compared, what is printed. Resolver/route: auth boundary, error → response mapping, parity claim + oracle. Rounds are r1 + r2 max; r3 needs chris's word, not the lead's.

30. **Fix-forward delta on an already-open PR: push first, vet in parallel** (D3365, chris "Yes", 2026-09-29): for a fix-forward DELTA on an already-open PR (the first tip still needed VET OK before push), the lane pushes at once and relaunches the round; I delta-vet in parallel. VET gates the MERGE, not the push. A failed delta vet = the lane fixes forward again; no lapse for the push. The first tip of a PR still needs VET OK before push.
