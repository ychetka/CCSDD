# review_panel.md - the multi-domain PR review panel

A pull request is reviewed by a PANEL of domain reviewers, not a
single monolith. Each domain judges the integrated delta under an
open-world predicate a frozen item contract cannot express; the
judge's per-item contract conformance is NOT re-litigated here.

## Registry

`canon/config/review_panel.json` is the single source of truth:

```json
{"signal_prefix": "ccsdd/",
 "verdict_transport": "status",
 "domains": {"<name>": {"class": "ci|llm|hybrid",
                        "gate_check": "<check_name>|null",
                        "required": true|false,
                        "profile": "reviewer_<name>",
                        "auto_pass_when_no_axes": true|false}}}
```

- `ci` - mechanical floor only (no agent, no signal).
- `llm` - agent verdict only (no floor).
- `hybrid` - mechanical floor + agent remainder. The floor is
  ALWAYS required at the merge gate even when `required: false`
  makes the LLM signal advisory - an advisory domain never
  disables its mechanical floor.
- `review.panel` in project.json may SUBSET the active domains;
  widening beyond the registry is rejected by check_setup.

Default panel: `specs` (ci), `security`, `quality`, `design`,
`tester`, `fidelity`, `docs` (hybrid, required) and `product`
(llm, advisory - promote to required after measuring its
false-positive rate).

## Mechanical floors and attestation

A `gate_check` resolves to `canon/bin/<check>.sh` (taken from the
BASE ref when canon is tracked, else from the deployed canon whose
per-file sha is pinned by the deploy manifest - never the
candidate's copy) or to a project argv from `gate_checks.<name>`
in project.json. A check that resolves to nothing may be declared
`gate_checks.<name>_optional: true` - an explicit opt-out recorded
in config (verify then reports N/A instead of missing evidence);
absent that flag an unresolved check fails closed.

`canon/bin/gate_run.sh run --check <c> --candidate <sha>` requires
HEAD==candidate and a clean tree, executes the check and appends a
record to `canon/gate_runs.jsonl`:

```json
{"ts","check","runner":"canon|project","script_sha256"|"argv",
 "base_ref","candidate_sha","exit_code","output_sha256"}
```

The journal entry is written by the tool itself - the agent calls
the wrapper, it cannot author the record. `gate_run verify`
re-checks exit_code==0 and (canon runner) `script_sha256` equal to
the base-ref blob hash (or the deployed-canon hash when canon is
untracked). Runtime journals the harness itself appends
(gate_runs.jsonl, cycle_log.jsonl, panel fixtures, signoff stores)
are exempt from gate_run's clean-tree check - they are
bookkeeping, not candidate content.

Project-argv floors (test suite, lint, SAST) EXECUTE PR code: they
run only in credential-free contexts (item worktree, merge-runner
candidate checkout is fine for canon scripts only). Canon floor
scripts must perform static analysis only - file reads, never
project code execution - so the merge gate may safely run them.
DAST and forge-side dynamic checks are declared in
`external_checks` and verified green in the PR rollup by the merge
gate, never launched by canon.

## Verdict records and signals

A domain reviewer publishes via
`canon/bin/panel_verdict.sh set --pr <N> --sha <head> --record v.json`:

```json
{"domain":"<name>","head":"<sha>","summary":"...",
 "receipt":["<files actually inspected>"],
 "findings":[{"severity":"CRITICAL|WARNING|MINOR|UNCERTAIN","text":"..."}]}
```

Severity taxonomy (identical to harness.md §4.6): CRITICAL/UNCERTAIN
are blocking and force `failure` mechanically; WARNING and MINOR
never block - a provably conformant implementation with secondary
remarks still merges. The verdict's WARNING count is journaled to
`canon/cycle_log.jsonl` per domain so accumulated non-blocking debt
surfaces in the risk:high human sign-off summary instead of
vanishing at auto-merge.

The signal state is computed MECHANICALLY (the record's own
verdict field is never trusted):
- any CRITICAL or UNCERTAIN finding -> `failure` (fail closed);
- otherwise -> `success`, emitted only when the domain's floor is
  green on --sha for hybrid domains.

`panel_verdict` publishes two artifacts atomically through the
forge adapter: a findings comment headed `## <domain> - review
@<sha8>` and a named per-sha signal `ccsdd/<domain>` with
state + description + the comment as target link. Signals are
bound to the exact sha: a new head invalidates every domain
verdict.

Severity caps live in the thin profiles (`quality`/`docs`: style
and prose may never emit CRITICAL) - a subjective nitpick must not
be able to force a full-panel re-review.

## Forge adapters

`canon/forge/<forge>.sh` implements the transport contract:

```
signal_set   --sha --context --state success|failure|pending
             --description [--url]
signal_get   --sha        -> {signals:[{domain,state,creator,...}]}
finding_post --pr --body-file -> {url}
```

`github.sh` maps signals to commit statuses and findings to issue
comments; `gitlab.sh` maps to GitLab commit statuses + MR notes
(negative verdict = failed signal + missing approve; GitLab has no
REQUEST_CHANGES primitive). `test.sh` is the offline fixture.
project.json `forge` selects the adapter; `verdict_transport`
documents the mechanism (status today, check runs optional later
on forges that support them).

## Launch model (director)

1. PR published; head sha H pinned.
2. Floors: project-argv checks are run by `gate_run` inside the
   credential-free candidate worktree during the cycle; canon
   floors may also be run at the merge gate.
3. Director reads the registry, spawns `reviewer_<domain>` per
   active llm/hybrid domain (parallel allowed; sequential is
   equally valid). Each reviewer reads its floor status, judges
   its lane, publishes its own signal.
   A domain whose floor reports no applicable input AND declares
   `auto_pass_when_no_axes` may publish `success` directly via a
   director-issued record - no LLM spawn needed.
4. Director mechanically verifies via `panel_verdict get --sha H`
   that every active domain reached a TERMINAL signal
   (success|failure) - respawning missing domains, never counting
   a missing one as pass.
5. The aggregator (`reviewer.md` profile) is spawned ONLY at the
   terminal condition. It publishes REQUEST_CHANGES when any
   required domain is != success (synthesizing deduplicated
   blockers), APPROVE otherwise - the only profile holding
   `repo_pr_review`, since one review identity means parallel
   formal reviews would overwrite each other.
6. REQUEST_CHANGES -> rework -> new head H' -> ALL signals
   stale -> full panel re-review on H'.
7. The merge gate (`panel_gate.sh`, invoked by issue_merge.sh)
   verifies: floor journal green at H for every declared
   gate_check (unconditional), required-domain signals success at
   H created by a review identity, external_checks green.

## Trust model

- Signal creator is the panel identity (review.* account), NOT
  the merge/author account - `bad_creator` blocks.
- The domain of a verdict is bound by the record's `domain` field
  and the spawn context; cross-domain forgery by a rogue spawned
  reviewer is the same trust class as a dishonest reviewer and is
  surfaced by the receipt + findings audit trail.
- `gate_runs.jsonl` is append-only runner state; the merge gate
  re-derives canon floors itself when it distrusts the record.
- The aggregator's formal review is bound to the head sha by
  repo_pr_review.sh (commit_id pinned); stale approvals do not
  count at the merge gate.
