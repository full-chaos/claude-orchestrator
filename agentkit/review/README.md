# codex review harness (copied 2026-10-03 from the bigboy lane dirs)

- `codex-review.sh.v4.8.24-ec6ccdabd870` — current wrapper (GWC lanes run it). Source: `.remember/lanes/_shared/`.
- `codex-review.sh.v4.8.22-4196253f5d53` — the version the acr/MCP lanes run. Source: `/var/lib/oci-cache/lane-scratch/_shared/`.
- `bigboy-start-gate.sh.v10-5b3ca085341d` — host round-cap start gate (cap 3; counts two wrapper processes per round, CHAOS-8414).
- `VET-CHECKLIST.md` — the vet checklist the rounds use.

File names carry version + sha256 prefix. The copies in the source dirs stay in place: live rounds call them by path.
Usage in lanes: `<wrapper> -w <worktree> -n <round-name> -m gpt-6-luna -e xhigh` with the prompt of record; verdict watch by wrapper pid.
