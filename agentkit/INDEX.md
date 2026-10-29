# agentkit INDEX (import 2026-10-29, CHAOS-11892)

Scripts copied byte-for-byte from this host. Source column = where it runs from today. Stale copies (.bak, -old, v1, retired, older rejected launchers) are not imported.

| tool | repo path | version | sha256[:12] | purpose | runs from today |
|---|---|---|---|---|---|
| codex-review launcher (current) | review/codex-review.sh.v4.8.33-720a36c9 | v4.8.33 | 720a36c9a76b | Codex review round wrapper; review/current points here | /home/ubuntu/devhealth/scripts/codex-review/ |
| review prompt of record | review/codex-review-prompt-of-record.md | 2026-09-16 | 069f3d5323fd | prompt used verbatim for every round | /home/ubuntu/devhealth/.remember/lanes/_briefs/ |
| review output contract | review/codex-output-contract.md | 2026-09-02 | 83fdf737e493 | verdict file contract | /home/ubuntu/devhealth/.remember/lanes/_briefs/ |
| vet checklist | review/VET-CHECKLIST.md | 2026-09-29 | 4295f692c9bd | checklist rounds use | /home/ubuntu/devhealth/scripts/codex-review/ |
| bigboy start gate | review/bigboy-start-gate.sh.v11-b725d329952f | v11 | b725d329952f | host round-cap start gate | /home/ubuntu/devhealth/scripts/codex-review/ |
| mergegate-mq | merge/mergegate-mq.sh | of record | a3e9e775d9b3 | merge-queue gate (final ops PR sha) | /var/lib/oci-cache/lane-scratch/shared/ |
| mergegate / gatedmerge / test | merge/mergegate.sh | - | 6e5a24ba7597 | older merge gate, wrapper, self-test (kept for reference) | /var/lib/oci-cache/lane-scratch/shared/ |
| prodroll | prodroll/prodroll.sh | v3j | 32c369a1eef2 | prod roll driver; reads sibling prodroll-v3/ kit | /var/lib/oci-cache/lane-scratch/shared/ |
| prodroll v3 kit | prodroll/prodroll-v3/ROLL-24d.sh | 24d | c2dbb9868777 | ROLL/POSTROLL/LOGWATCH/HEADROOM/RENDER-PATHS/READBACK/START-CHECK scripts, DESIGN.md, SHA256SUMS, tests, examples | /var/lib/oci-cache/lane-scratch/shared/prodroll-v3/ |
| pcheck | ci/pcheck.sh | - | 81637837cd1c | PR check helper | /var/lib/oci-cache/lane-scratch/shared/ |
| mcheck (+ nonpass test) | ci/mcheck.sh | - | 40c14b129471 | merge check helper | /var/lib/oci-cache/lane-scratch/shared/ |
| known-red | ci/known-red.tsv | - | 3b5a273eccb5 | known red CI checks list | /var/lib/oci-cache/lane-scratch/shared/ |
| capped.sh | ci/capped.sh | D6265 | 831d995a6387 | run a command under wall-clock + memory cap (all go test) | /home/ubuntu/devhealth/scripts/ |
| tool fetch | tools/fetch-tools.sh | new | 46096132510e | fetch shellcheck 0.11.0 + actionlint 1.7.7 (binaries not committed); new file, not a copy | - |
| lane brief templates | briefs/pm-lane-common-2026-10-29.md | - | 09f37fa7ef8a | pm lane common, scribe-pm, resume-common, this lane's brief | /home/ubuntu/devhealth/.remember/ |

Older launchers v4.8.22..v4.8.32, test-*.sh and logs are in review/ for history. Not imported: stale copies under ~/.local/lib/dev-health-review, .remember/lanes/_shared, lane-scratch/_shared, scripts/codex-review.sh.RETIRED-2026-09-18, all .bak files, prodroll-v1, prodroll-v3.*-old, tool binaries.
Also seen, not copied: /home/ubuntu/devhealth/lib.sh is a one-off bbquiet4 helper; scripts/{kind-up,kind-down,bootstrap-acr-production,start-stripe}.sh are ops helpers.
