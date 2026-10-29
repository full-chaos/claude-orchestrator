# Codex verdict output contract — CORRECTED 2026-09-02 14:05 (supersedes lane-s7c/OUTPUT-CONTRACT-SNIPPET.md and the 13:11 addendum)

## Root cause of every lost round today (PR2 ×3, 4855 ×1, S7c rev-2)
`scripts/codex-review.sh:173` runs `codex exec … -o "$V"`. In `codex exec`, `-o` is `--output-last-message <FILE>`:
codex writes the reviewer's FINAL REPLY MESSAGE to that path when the run ends. Our prompts told the reviewer to
write the report INTO that file itself and said "the reply is not collected". So the reviewer wrote a full report
to the file, then replied with a one-line summary — and codex overwrote the report with the summary. Rounds that
"worked" were the ones where the reviewer happened to put the whole report in its final reply.
Evidence: PR2 round 2 log shows ~120 lines written to the exact -o path and 2 lines landed; round 2c = 180 bytes,
no trailing newline (a chat message, not a file write); 4855 round 1 = a pointer to files it wrote elsewhere.

## Paste this, verbatim, as the last section of every prompt
```
## Output contract

Your FINAL REPLY MESSAGE is the review. The harness captures your final message to the verdict file itself.
Do NOT create or write any file: not the verdict file, not a report, not a scratch note. Anything you write to
disk is discarded and anything you say in an earlier message is discarded. Only your last message survives.

Your last message must be the complete, self-contained report: one section per finding with severity, a literal
`path/to/file.go:LINE` citation, the reasoning, and the repro as a line starting with `$ ` followed by its
output; then the verdict on its own final line: `VERDICT: CLEAN` or `VERDICT: NOT CLEAN`. A last message that
summarises, points to another file, or omits citations is a NO-VERDICT and the round is lost. Write the full
report as your last message even if the analysis was long.
```

## Acceptance (lane side, unchanged)
Read the wrapper's exit code directly (no pipe). Verdict file: ≥ 1 `path:line` citation per finding (any file type the diff touches, e.g. `[A-Za-z0-9_./-]+:[0-9]+`; not `.go`-only — a YAML/Python diff cannot cite a .go line), ≥ 1 `$ ` line
when findings exist, `VERDICT:` as the last line. No line-count minimum (13:15 PDT: GW's #2131 caught a real false
green in a 10-line verdict; length is not evidence). Anything else = NO-VERDICT, does not count, report it.
