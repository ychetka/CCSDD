# Harness: two-committee development cycle

Specification of the development cycle with AI orchestration. Version
1.0, approved by the developer 2026-10-29. Design source:
`ai_assisted_development_v1_0.md` (adapted for a solo developer after
three rounds of consultations with external partners).

## 1. Principles

- Two levels of abstraction: the project root agent instance
  operates at the high level (roadmap, contracts, statuses); the
  executor subagent operates only at the low level (one item, one
  module, its own contract and files).
- Contract-first: a module is defined by its external contract before
  code; executors of different modules can work in parallel and
  independently.
- A roadmap item = an autonomous task = an output artifact.
- Human checkpoints: roadmap approval (and contract sign-off) before
  code, plus escalations from the list. There is NO separate
  "release merge" gate (tag-always ruling 2026-11-17): every merge
  into the DEFAULT branch via repo_merge.sh checks the version bump
  itself, and after the merge tags + cuts the release — the
  third-level human gate is
  abolished, release discipline moved into the objective gate.
  Merges into non-default bases (task → epic) merge without a
  release.
  Everything in between — autonomous.
- The human is maximally involved at the design stage and minimally
  during implementation against an approved spec: the implementation
  result must be predictable from the frozen contract and the
  criteria fixed before the start.
- All external model calls (partners, external architect, second
  family) — only through the unified gateway via Audit/Consult
  profiles; direct calls from an agent instance are forbidden (see
  `gateway.md`).
- Human decisions that affect gates are recorded as an immutable
  decision envelope (see §3) — not as a mediator's text.
- The worker lives inside an orchestration instance (terms —
  `fleet.md`, `glossary.md`): one orchestrator per bus, its own
  STATE, an interaction journal.
- Quality = tests passed + review passed. No live metrics; a raw log
  is kept for retrospectives.

## 2. Roles and committees

### Architecture committee

Designs roadmap.md and the design of each item.

- Root director (the main agent instance in the repository) — the
  author.
- architect-partner, product-partner — co-designers (top-tier
  models; canonical roles in `config/partners.json`, the concrete
  model binding is a project setting). Calls go through the
  gateway, Consult profile (`gateway.md`); design disputes taken
  to external arbitration — ex-architect-partner, Audit profile.
- The developer — arbiter and final approval.

Co-author disputes: the author (root) picks a variant and logs it in
the roadmap's `## Design Dissent` block (`chose A
(Root/architect-partner) over B (product-partner) because X`). The
developer sees all disputes at approval and may override. No voting.

### Executive committee

Implements one roadmap item.

- The executor (a `code_writer`-profile subagent, narrow context) —
  the code author. Profile: `canon/agents/code_writer.md`; instance
  per repo — `canon/agents/code_writer.md` (next to
  git/hygiene/repository/reviewer).
- code_writer contract: a PR/report is delivered only on a green
  native project run (lint entrypoint + tests + typecheck). Lint
  config lives in the project's native files
  (pyproject.toml/package.json/Makefile) — the harness only calls
  the entrypoint; canon/ has no lint config of its own and must not
  have one.
- The designer (a `designer`-profile subagent,
  `canon/agents/designer.md`) — a CONDITIONAL member, spawned only
  for items whose contract declares a `## Delegated decisions` block
  with at least one axis. It resolves every declared axis into an
  impl spec (decision + constraint_check + alternatives per axis)
  BEFORE the code_writer starts; the mechanical gate
  `canon/bin/design_spec_check.sh` must pass on the spec before the
  writer is spawned. The designer writes no code, resolves nothing
  outside the declared axes (undetermined → `contract_gap`
  escalation) and holds no verdict power — the judge verifies its
  coverage.
- design-partner, product-partner — consultant co-authors
  (workhorse tier; consultation before spawn and on demand, through
  the gateway, Consult profile).

### Partner consultation protocol — conflict-directed rounds

Consultation is NOT an open deliberation and never a
partner-to-partner exchange — the director is the only packet
assembler and partners stay stateless at every round:

- Round 1 — blind: each consulted partner answers the SAME verbatim
  packet independently; no partner sees another's answer.
- Rounds 2..k (k ≤ 2 by default) — conflict-directed only: the
  director extracts divergence points and sends each partner ONLY
  the counterarguments against its own position or its own domain,
  anonymized ("a colleague argues X, conflicting with your Y —
  defend or concede"). A partner is never shown a consensus or a
  majority framing — the round cannot wash out into
  agreement-pressure.
- Outcome: converged — the dissent is closed without reaching the
  human; still divergent — `## Design Dissent` records the argued
  positions verbatim for the arbiter.

### Reviewers (outside the committees)

- Item judge — a subagent of the root instance, fresh bounded
  context, repo access.
- Review PANEL (specs/review_panel.md) — PR level: per-domain
  reviewers (reviewer_<domain> profiles over
  agents/reviewer_protocol.md) publish named per-sha signals
  `ccsdd/<domain>` via panel_verdict.sh; the aggregator
  (reviewer profile, separate account) publishes the single
  formal PR review via repo_pr_review.sh once every active domain
  reaches a terminal signal.
- Auto-review on MR — a repository bot triggered by push (project
  configuration, not canon).

Review independence is mechanical: judge and reviewer issue verdicts
only on COMMITTED artifacts (the PR diff, the contract in the repo,
gate-script run results) — not on the executor's self-report and not
on the uncommitted state of the working tree.

Invariant: one agent instance never holds both authorship and
approval.

## 3. Artifacts

The artifact layer is pluggable per project type: git+PR is one
binding (a canon project-type profile); a repository may hold not
only code but also specs, diagrams, roadmaps, backlogs, contracts
and release history. For non-git repositories an adapter fixes a
snapshot hash; review runs against the snapshot, apply is done by
the adapter; the invariants (verdict independence, hash freezing,
decision envelopes) hold regardless of the binding.

### roadmap.md

Lives in the repository's `canon/`, is NOT published (a working
process document: live statuses, verdicts, disputes — not for the
repo tree and not subject to the English-only/no-AI-names rules of
public repositories). Available to subagents locally.

- Header: stack/architecture/FE-BE boundary decisions (fixed before
  code), an index of active contracts with statuses, the global
  acceptance command, `## Design Dissent`.
- Items: template `templates/roadmap.template.md`.

### CONTRACT (object)

- A `contract.py` file (Pydantic v2) or `contract.ts` (types +
  ajv/zod where runtime validation is needed) — a regular source
  file, committed to the repo, colocated with the module. Contains
  input/output, errors, side-effect description. Do not keep a
  central contracts/ folder.
- Status in roadmap.md: draft > judged > signed_off.
- Sign-off = an explicit "approved" by the developer after the
  judge's pass. Sign-off freezes the contract BY HASH: the contract
  registry and the decision envelope record the sha of the contract
  file at approval time; the judge and the merge gate verify exactly
  that hash — "a different text was approved" is impossible.
- Implementation/test items read the contract read-only and do not
  start without signed_off.
- Changing a contract — a new contract item or PLAN_DELTA (what
  changes + which items are invalidated) for developer
  approve/reject. Never an executor edit on the fly.
- A contract MAY carry a `## Delegated decisions` block (inside
  the contract file — it freezes together with the sign-off
  hash): an explicit list of freedom axes, each with its
  constraint, one per line as
  `- axis: <name> | constraint: <binding constraint>`
  (e.g. `- axis: control_placement | constraint: must comply
  with the design system`). The line format is mechanical:
  `design_spec_check.sh` parses it (p.4b).
  Everything the contract neither requires nor delegates is a
  CONTRACT GAP, not freedom — see p.4c.

### Human decision envelope

An immutable record of a human decision that affects a gate
(sign-off, manual_gate, dispute resolution, canon release):

- Fields: verdict, hash of the artifact/revision the decision
  applies to, verbatim supporting material, decider role,
  timestamp.
- Mechanism (product gates): `canon/bin/human_sign.sh` — an SSH
  signature over the canonical message
  `ccsdd-signoff v1|<verdict>|<artifact_sha>|<utc>|<nonce>` made by
  an ssh-agent-resident key (`ssh-keygen -Y sign`); the private
  key never enters the workspace filesystem, so a workspace agent
  cannot mint a signoff. `human_sign.sh init` writes
  `~/.config/ccsdd/allowed_signers` once. `sign` supports two
  transports for the SAME signed payload: `--out <file>.json`
  writes the envelope to `canon/human_signoffs/<branch>.json`,
  while `--out -` prints a compact single line
  `CCSDD-SIGNOFF-1|<verdict>|<artifact>|<ts>|<nonce>|<sig_b64>`
  the human can paste into the agent chat — the remote-laptop
  workflow where signing happens off-server and the chat is just
  transport (the line is still a cryptographic envelope, not a
  "verbal" approval; a pasted plaintext "approved" is rejected).
  `verify` accepts the JSON envelope, a file holding the compact
  line, or the literal line — the compact fields expand into the
  same envelope, so every check is identical: signature against
  `allowed_signers` (which lives OUTSIDE the workspace), the
  exact artifact/verdict binding, a 7-day freshness window and
  nonce anti-replay (`canon/human_signoffs/.used_nonces`, stored
  per artifact: the same envelope re-presented for the same
  artifact is an idempotent retry, for a different one - a
  replay) — a captured envelope cannot approve a different
  artifact, a different verdict, or a second merge.
  Contract sign-off envelopes follow the same verify path plus a
  supersede check: their nonce is NOT consumed at merge — the
  same contract's envelope legitimately verifies on every merge
  the contract gates. Instead `issue_merge` records the contract
  file's pre-merge content hash in
  `canon/human_signoffs/.superseded_contracts`, and `verify`
  rejects any envelope whose artifact was superseded — a later PR
  that rolls the file back to a superseded hash cannot resurrect
  an old approval.
- Written into the instance STATE (managed mode) or into the cycle
  artifact journal (direct mode) — never passed as text through an
  LLM intermediary.
- The gate checks the envelope mechanically: a decision is valid
  only if the artifact hash in the envelope equals the hash of the
  reviewed/merged object. A decision "in general" or about a
  different revision does not count.
- Question routing and answer authenticity are different things:
  the question may travel through the orchestrator, the envelope
  bypasses it.

### docs/specs/ (living spec)

The registry of the system's current behavior — answers the
question "how is it built now". Public, English-only, committed to
the repo (this is system documentation, not a process artifact).
Structure: `docs/specs/<domain>.md` — one domain = one file.

Requirement format — scenario-style, G/W/T-compatible:

```markdown
### Requirement: quota-park on explicit model limit
The bridge SHALL park a step on an explicit model rate-limit
error carrying a reset time.

#### Scenario: park until reset
- **WHEN** a step reports rate-limit error with reset_at
- **THEN** step_state becomes waiting_quota until reset_at
- **AND** retry budget is not consumed
```

`Requirement` names are stable — `.changes` and coverage checks
reference them.

Updates — only via deltas through `.changes/<slug>.md` (the single
specification of the fragment schema is the "Versioning and
releases" section below; only the delta mechanism is described
here). Mandatory `## Spec impact` section with `adds:` /
`modifies:` / `removes:` lines — anchors of the form
`docs/specs/<domain>.md#<requirement-anchor>` (a bare `-` when
there is no behavioral impact). Anchor semantics:

- `adds:` — the requirement appears in the spec with this PR; the
  anchor MUST resolve in the target file on the PR branch (it need
  not exist on the base branch).
- `modifies:` — the requirement exists on the base branch and
  changes; the anchor MUST resolve before merge.
- `removes:` — the requirement is deleted; the anchor MUST resolve
  on the base branch and is EXPECTED to disappear after merge — the
  anchor's absence from the target file after merge is normal, not
  a validation error.

The delta is applied in the same PR as the code — atomically; spec
and behavior do not diverge. Check: anchor validation in
`verify_constraints.sh` / CI — every Spec impact anchor must
resolve in the target file (protection against dangling links).

Boundaries: spec — system behavior; roadmap — work and statuses;
contract.py/ts — types (the spec references, does not duplicate);
ADR — decisions and reasons. Backlog ideas and unaccepted plans
never enter the spec — only what is already in the code.

Agent-instance rule: for "how is it built now" look at `docs/specs/`
first, then code. A spec<>code divergence is a defect, fixed by a
delta in the next PR.

### harness_log.jsonl

In the repo's `canon/`. One JSON line per branch item, written
after the item's terminal outcome (PR merge, terminal escalation,
abandon) — the outcome is recorded as fact, not forecast. 8 fields:

```json
{"ts_utc": "2026-03-01T12:00:00Z",
 "item_id": "item_03", "category": "implementation",
 "arch_revisions": 1, "exec_review_rounds": 2,
 "deviations_reported": {"autonomous": 1, "contract_escalations": 0},
 "model_tier_upgraded": false,
 "final_outcome": "merged_clean",
 "friction_note": "worker fought mock setup in tests"}
```

- category: contract | implementation | test | refactor | docs | exploration | infra | epic
- arch_revisions: iterations of item approval in the arch committee
- exec_review_rounds: judge/reviewer rounds (1, 2, 3+)
- model_tier_upgraded: whether exec-committee models were upgraded
- final_outcome: merged_clean | merged_with_deviations | escalated | abandoned
- friction_note: one line — what slowed things down most

Append — only via `canon/bin/harness_log.sh append` (validates
enums and counters, holds flock; writing the file by hand is
forbidden).

### failure_class — canonical enum

A single set for `cycle_log.jsonl` and all gate-script JSON
responses (`repo_merge.sh`, `repo_release.sh`, `repo_pr_review.sh`
etc.); `cycle_log.sh append --failure-class` validates against it:

`gate_blocked | merge_conflict | ci_failed | permission_denied |
stale_head | malformed_input | upstream_error | upstream_timeout |
missing_changes_entry | version_not_bumped | version_source_missing |
version_drift | conflict | contract_gap | contract_ambiguity |
unverifiable | scope_conflict | quota_limited | incomplete_read |
not_found | manual_gate | epic_incomplete | missing_issue_field |
issue_mismatch | stale_input | plan_drift | verify_escalated | verify_failed |
release_failed | missing_review_domain | bad_creator |
external_check_failed | panel_incomplete | missing_panel_registry |
panel_domain |
baseline_unresolvable | env_setup_failed | unauthorized |
already_exists | unknown`

### cycle_log.jsonl

In the repo's `canon/`, an append-only journal of cycle events via
`canon/bin/cycle_log.sh` (direct file writes are forbidden, flock +
tmp+rename). Events:

- `append` — records an actor's action result:
  `{ts, item, actor, action, expected, result, status, verdict,
  failure_class}`; `verdict=failure|escalated` must carry
  `failure_class`; `verdict=ok` — never.
- `close` — closes open records with an append-only event
  `{..., action: "close", closed_by, closer_role,
  token_authenticated}`: history is not rewritten, the original
  verdict stays auditable; "openness" is derived by folding the
  event stream.
- `register` — registers an actor in `canon/actors.json`
  (`{actor_id, role, token_sha256, registered_at, project}`); the
  token is issued once and lives only in the actor's context
  package. Privileged roles (`orchestrator`, `director`) require
  `--registrar-token` of an already-registered privileged actor
  (bootstrap — when the privileged registry is empty); rotating an
  existing actor's token — only with its own `--token` or
  `--registrar-token`.
- `append --action close|resolve_*` (clearing events) requires the
  caller's `--token` (`--by`, default = `--actor`) and writes
  `token_authenticated: true`; the `close` and `verify_constraints`
  rollups count a resolution only for such events. Cross-actor
  resolution — only for `orchestrator`/`director` roles.

Close authorization: an actor closes its own records; others' —
only `orchestrator`/`director` via `--for-actor`. Records with
`verdict=escalated` are incidents awaiting the developer: their
closing is always privileged (only `orchestrator`/`director`/
`resolver` roles), including the actor's own records — an executor
cannot "wash out" its own escalation.
Globally, several
orchestrators with scoped ownership may exist (disjoint sets of
tasks/instances — e.g. when one runs out of context window); two
orchestrators on one project is a forbidden case. Roles:
orchestrator, root (director alias per policy.json), director,
executor/code_writer, designer, judge, reviewer, resolver,
repository, git, reader, hygiene, partner, and the seven panel
domain reviewers reviewer_<domain> (design, docs, fidelity,
product, quality, security, tester).

Actor retirement: when an agent instance ends, its record in
`actors.json` is removed by `cycle_log.sh unregister` (with the
actor's own `--token` or a privileged registrar's
`--registrar-token`) — the token immediately stops authorizing
close. An orchestrator removes its registrations when going into
retirement (orchestrator handover/retirement = registry transfer:
the new orchestrator registers via bootstrap or via the departing
one's `--registrar-token`; the departing one is unregistered).

### Time zones (canon)

- Stamps on outgoing messages (`YYYY-MM-DD HH:MM` via
  `msg_stamp.sh`, answer headers) — **host local time** (the zone
  where the human lives; the `orc_turn_start` NOW-line prints it).
- The quota protocol (`QUOTA_RESET_AT`, `waiting_quota`), logs
  (`cycle_log.jsonl`, `harness_log.jsonl` ts_utc) and any
  machine-readable marks — **strictly UTC**. Mixing zones in one
  field is forbidden.

Retrospective: after 15-20 items the log goes to product-partner for
bottleneck analysis — metrics appear then.

### The director-instance model (event-driven, approved 2026-11-11)

The worker instance = the project director: does not write code
itself, delegates to background executors and lives in SHORT
event-driven turns. Goal: the instance is almost always available
for orchestrator mail and questions — availability is achieved by
releasing the slot, not by holding it forever.

Principles:

- **Event-driven turn**: the director wakes only on an event —
  (A) an orchestrator letter/directive, (B) background-executor
  completion/crash, (C) a monitoring checkpoint tick. Every turn
  ends fast: drain -> decision -> end of turn.
- **Turn length limit T** (default 30 min): a turn longer than T is
  an architectural error. Long work = a background executor +
  mandatory checkpoints every T minutes (update task status, drain
  mail, extend the lease via `bridge wait`).
- **Background-executor limit** — `director.background_executors`
  in canon/project.json (default 1, MVP): a parallel zoo of
  subagents above the limit is forbidden. Executor contract:
  `{task, context_slice, deadline, report_to}`; step deadline = the
  turn limit T (default 30 min, one value for the whole model);
  retry cap — max 3 before escalation.
- **Blood signature — mechanical only**: the director does NOT
  report on the executor's word and does not run git itself (direct
  git by the agent instance is forbidden) — verification is
  performed by
  the whitelisted `verify_worktree.sh` script whose JSON report the
  director quotes verbatim; before merge the gate itself runs
  `verify_constraints.sh` + `verify_worktree.sh` on a detached
  worktree of the PR tree. Baseline verification is NETWORK-FREE
  by default for EVERY stack: the Python baseline imports the clean
  worktree via `PYTHONPATH` instead of `pip install`, so no
  unpinned dependency resolution and no candidate build backend
  (`setup.py`, `pip install -e`) can execute during attestation;
  the JavaScript baseline likewise runs against an already
  prepared `node_modules` (`NODE_PATH` + `node_modules/.bin` on
  `PATH`) instead of a networked `npm ci` - the detached verify
  worktree never carries `node_modules`, so dependencies resolve
  from the prepared main workspace (or a `baseline_env.sh`-
  populated dir); neither present is `env_setup_failed`, not a
  skipped baseline. A deployed,
  hash-pinned `canon/baseline_env.sh` MAY provide a prepared
  environment; `VW_ALLOW_INSTALL=1` is a local/debug-only override
  that normal gates never set.
- **Kill-switch**: a STOP directive from the orchestrator is
  executed by the daemon: `bridge agent-kill --agent <agent_id>`
  sends cancel directly to the executor instance's runtime,
  bypassing the mail queue (a STOP letter could sit while the
  instance is not polling mail). The executor is killed BEFORE
  answering the letter. Fallback — a targeted kill of the hung
  local runtime process of that executor (not a blanket stop of
  the whole instance).
- **Lease != progress**: `bridge wait` extends the lease only while
  the executor is alive (a progress note with substance, not an
  empty ping).
- **Review — external only**: the panel's domain reviewers are
  spawned by the director at PR assembly (the director is the only
  spawn owner in the instance), but there is no conflict of
  interest: verdict independence is ensured by the separate
  reviewer account declared in `project.json`
  (`review.reviewer_logins`, `review.reviewer_profiles` —
  per-identity `{api_bin|gh_bin, model_family}` entries;
  `review.gh_bin`
  remains the default profile; a profile MAY be marked
  `high_risk_only: true` so a second-family reviewer account
  exists for `risk: high` changes without making its verdict
  mandatory on ordinary PRs) and by direct publication via
  `panel_verdict.sh`/`repo_pr_review.sh` — the director can
  neither edit a verdict, nor filter its publication, nor approve
  its own PR. Domain reviewers never hold `repo_pr_review`: the
  aggregator is the only formal-review publisher (one review
  identity → parallel domain reviews would overwrite each other).
  Merges run under the repository-agent credential
  (`merge.gh_bin`), never under a reviewer identity — least
  privilege, no self-approve channel.
- **Mid-turn inject — closed empirically (2026-11-11)**:
  `session/prompt` on a busy instance is rejected by the host
  immediately ("a turn is already running") — it is neither queued
  nor injected. The event-driven model is the only path; 'always-on'
  is unreachable.

### Versioning and releases

The version policy is fixed at roadmap approval, not at merge
(developer decision 2026-11-11):

- **Release type — in the roadmap**: every item has a
  `release: patch | minor | major` field, assigned and approved
  together with the plan. 1 functional feature — minor; 1 major
  feature (architectural shift / breaking change) — major; fixes,
  tooling, docs — patch. The concrete version number is NOT
  reserved — it is computed at merge (Release-on-Merge).
- **Branch**: `issue_<N>-<slug>` for a task/item branch,
  `epic_issue_<N>-<slug>` for an epic branch (no version in the
  name); a
  mandatory `.changes/<slug>.md` fragment with fields
  `bump: patch|minor|major`, `user_visible:`, `issue:` — on the
  branch BEFORE the PR merge. Every merge to the base branch
  releases (developer ruling 2026-11-17); drafts, experiments, and
  exploration that must not ship live on their own branches
  outside the merge path — there is no merge-without-release
  value. The fragment's `issue:` is verified
  mechanically: it must name an issue the PR is about — the
  `issue_<N>`/`epic_issue_<N>` of the head branch or any `#N`
  referenced by the PR body (an epic PR legitimately carries task
  fragments with their own issue numbers) —
  `failure_class=missing_issue_field`/`issue_mismatch` otherwise.
  The field tolerates the natural forms - `issue: 10`, `issue: #10`,
  `issue: 10, 11` (several references), `issue: "10"` (quoted);
  parsers extract every number independently and never weld digits.
  Optional `risk: high` on a fragment marks the change as
  high-risk: the merge gate then requires approving verdicts from
  reviewer profiles of AT LEAST TWO DISTINCT `model_family` values
  (profiles flagged `high_risk_only` participate only here and are
  not required for ordinary PRs) PLUS the human approval envelope
  (same SSH-signature factor as `manual_gate`). A project whose
  configured profiles expose a single family can never satisfy the
  rule - `check_setup.sh` fails that configuration.
  The binding runs both ways: a roadmap item with a non-empty
  `risk_flags:` MUST be shipped with a `.changes` fragment
  declaring `risk: high` - `verify_constraints.sh` check 6d
  escalates the omission, so the escalation path cannot be
  silently bypassed by leaving the flag out of the fragment.
  Optional `manual_gate: true` on an
  item with `manual_gate` in the roadmap: `repo_merge.sh` blocks
  the merge (`status=blocked`, `failure_class=manual_gate`) until
  the developer signs the exact head SHA with the SSH signature
  factor: `human_sign.sh sign --verdict approve
  --artifact <head_sha> --out canon/human_signoffs/<branch>.json`
  — the gate mechanically verifies the envelope
  (`human_sign.sh verify`); no envelope or a stale/mismatched one
  keeps the PR blocked
  (`failure_class=missing_changes_entry`/`malformed_input`
  otherwise). The version file on the branch is NOT bumped. A merge
  without a fragment is gated by `repo_merge.sh`.
- **Epic decomposition**: a roadmap item MAY be an epic decomposed
  into tasks. The epic lives on its `epic_issue_<N>-<slug>` branch;
  each
  task is its own item with its own `issue_<M>-<slug>` branch and
  merges into the epic branch through the same objective
  `repo_merge.sh` gate — reviewer approvals + required checks, no
  human gate. When a task lands on the epic branch the
  repository-agent CLOSES its issue (`repo_issue_close.sh`) — a
  task is done when its fragment is on the epic branch AND its
  issue is closed. A merge into a NON-default base is integration,
  not
  publication: `repo_merge.sh` merges it but skips Release-on-Merge
  (`release.status=skipped`, `reason=non_default_base`) — no version
  bump, no tag. Task fragments accumulate on the epic branch and are
  consumed by the epic's release. The epic's own merge into the
  default branch is the release boundary — and the point where a
  `manual_gate` item waits for the developer's approval.
- **Merge-gate dispatch**: `repo_merge.sh` routes by the head
  branch — `epic_issue_<N>-<slug>` heads go through
  `epic_merge.sh` (which adds the EPIC COMPLETENESS GATE before
  delegating), every other head through `issue_merge.sh` (the
  common objective pipeline; calling it on an epic head directly
  is blocked).
- **Epic completeness gate** (`epic_merge.sh`): the epic's
  `canon/roadmap.md` item — matched by `issue: <N>` — must declare
  `type: epic` and `tasks: [<issue numbers>]`. Every declared task
  must be shipped (a `.changes` fragment with `issue: M` in the
  base...head diff) AND closed in the tracker. Missing roadmap
  item/fields or pending tasks → `status=blocked`,
  `failure_class=epic_incomplete`; an epic never merges partial.
  `tasks:` lists shippable task items ONLY — an `exploration` item
  is wired to the epic through `depends_on`, never through
  `tasks:` (explorations produce answers, not release fragments;
  putting one in `tasks:` deadlocks the gate on a fragment that
  can never exist).
- **Release**: after a merge into the DEFAULT branch
  `repo_release.sh` computes
  `next = bump(max(latest v* tag, version source on base))` by the
  maximum `bump:` among fragments, writes the release commit on
  base (version file + `.changes` rollup into CHANGELOG + fragment
  consumption), tags `v<next>` and publishes the GitHub release.
  Parallel branches do not compete for a number — merge order
  determines the final version automatically. When the base branch
  is protected, the release commit rides on branch
  `release/v<X.Y.Z>`: that PR passes the same objective
  `repo_merge.sh` gate (the `release/v*` branch is allowed by
  `verify_constraints.sh`), and after merge the resume path of
  `repo_release.sh` tags the resulting head.
- **Release history**: besides the tag and CHANGELOG, every
  publication leaves a durable record in the cycle artifacts
  (release journal): version, tag, hash, merger, approval
  envelopes, final review verdicts, UTC date. The release journal
  is the audit source of "who released what, when and why" on top
  of GitHub release links.
- Canonical orchestrator rollouts: canon_version is bumped by the
  manifest + a `canon-v<canon_version>` tag on the canon source
  repository (its own cycle, outside worker RoM gates; the
  `canon-v*` prefix is a separate semver space from product `v*`
  tags). Canon owner — one instance (the `canon_owner` mark in
  FLEET, assigned by the human, see `fleet.md`); drafts live in the
  owner's canon work area, publication — through the canon gate
  with a human approval envelope (see §3 "Human decision
  envelope").

## 4. Item lifecycle

0. **Repository bootstrap (deployment)**: `canon/bin/setup_repo.sh`
   is run once by the deployer (or the repository agent) per target
   repository: it deploys `.github/workflows/release.yml` FIRST —
   the serialized `release-main` concurrency group that finalizes
   tags/releases for merged `release/v*` PRs server-side, so two
   merges can never race the version/tag order — and only then
   applies canonical branch protection on the base branch (PR
   required, stale-review dismissal, no force pushes). The order
   matters: protection applied first would make the workflow
   deploy PR unmergeable under its own new rules; on an already
   protected base the same direct write succeeds under an admin
   token (`enforce_admins: false`), and any PR-based bootstrap can
   never merge under the canon's own rules — so a refused write is
   an operator action (admin token / temporary protection removal /
   manual commit of the template), not a fallback branch. The
   script resolves the repo from `git remote`, requires gh
   credentials, and is idempotent.
1. The arch committee designs the roadmap (items, types,
   dependencies, contracts, stack/FE-BE, G/W/T, risk flags, Design
   Dissent) > developer approval. For a repository without CI the
   roadmap MUST start with an infra item: `.github/workflows/` —
   lint + tests (stack-equivalent: ruff/pytest, eslint/vitest,
   etc.), triggers push to base branch + pull_request. Until the CI
   item merges, the success criterion is a local run; after merge a
   green CI is mandatory on every PR.
   A canonical check baseline ships with the canon: lint, tests,
   typecheck + security scanners (Trivy, Semgrep or equivalent).
   The canon project-type profile selects the applicable subset —
   scanners live in the same CI as tests and linter; their failure
   blocks merge.
2. ISSUES: after roadmap approval every item is filed as a separate
   issue in the project's task tracker (repository issues). Issue
   links/numbers are written back into roadmap.md; branch names and
   tracking follow them. Implementation does not start until all
   issues are filed.
   Backlog: ideas, deferred findings, tech debt and research
   questions are filed as issues with the `backlog` label — a
   candidate, it guarantees nothing; an issue becomes a roadmap
   item only upon roadmap approval and survives replanning.
2a. Planning phase (optional, at the developer's request): after
   roadmap approval and issue creation the developer may request
   batch elaboration of the first N items' contracts before any
   implementation starts. Each contract goes through the normal
   pipeline (executor > judge > sign-off), but sign-off is done in
   one focused pass by the developer — an envelope is still issued
   per contract, each with its own sha.
   Batch sign-off does not freeze the roadmap: if by the time the
   item spawns its context has drifted (dependencies changed, early
   items' code landed), root must re-run the contract through the
   judge (re-judge) or open a PLAN_DELTA — implementation on a
   stale signed_off contract is forbidden; contract freshness is
   checked by the judge at item spawn.
3. Contract item: the executor writes the contract file > judge >
   developer sign-off (blocking checkpoint).
3a. Test item (standalone): an item whose artifact is only tests
   (coverage of existing code, regression tests). Goes through the
   same cycle: G/W/T scenarios in the item text, the judge verifies
   that every scenario is covered by a test with a verbatim id and
   that the run is green; the item adds no functional code — the
   diff scan does not require a `.changes` behavioral impact (a
   fragment with `bump: patch` and `## Spec impact` bare `-` is
   allowed).
3b. Infra item (repo without CI): adds `.github/workflows/` and
   tooling; the judge verifies a local run instead of CI (CI does
   not exist yet), then the item follows the normal cycle.
4. Implementation item:
   a. Partner pre-consultation on the item: {item text + contract
      inline + 1-line dependency summaries} with the question "find
      holes in the criteria and stack pitfalls, do not write code".
      The answer — a structured JSON list of flags; root attaches
      them to the item as additional_acceptance_notes. Not for
      docs/refactor items.
   b. If the contract declares a `## Delegated decisions` block with
      at least one axis: spawn the designer FIRST (§2). The designer
      returns an impl spec — one decided entry per declared axis —
      which the calling instance commits as the tracked artifact
      `docs/impl_specs/<item_slug>.md` on the item branch
      (repo_language; English by default), so the fidelity floor
      sees it in the PR delta. `docs/impl_specs/*` is scope-checked
      like any other path: the calling instance commits the spec
      BEFORE the executor's scope_whitelist.txt is installed, so an
      executor may touch the spec only when its whitelist names the
      path explicitly - otherwise the writer could retro-fit the
      designer's decisions to its own code. The
      mechanical gate `canon/bin/design_spec_check.sh --contract
      <contract-file> --spec <impl-spec>` must pass BEFORE the
      executor is spawned: a declared axis left undecided or a spec
      entry naming an undeclared axis fails the gate (designer
      rework; a wrong axis set is a contract_gap → arch committee).
      Then spawn the executor with a package (p.5) that includes the
      impl spec. With no declared axes the designer is not spawned
      and the step reduces to a plain executor spawn.
   c. Mandatory pre-code interrogation: the executor records in the
      item journal a structured interrogation BEFORE writing code —
      assumptions, ambiguities, readings of criteria. The
      interrogation is an exec-committee artifact, not a direct
      question to the human; an empty interrogation is itself a
      signal to the judge. Every undetermined point is mapped to
      either a `delegated_decisions` axis declared in the contract
      or a contract gap. A gap — found pre-code or discovered
      mid-implementation — is NEVER resolved by improvisation: the
      executor reports `OPEN: contract_gap(<question>)` and the
      question climbs the escalation ladder to the arch committee
      (§6), which refines the contract (a new sign-off hash). The
      item does not proceed in implementation while a gap is
      unresolved.
   d. Executor (code_writer): works inside the item's worktree —
      the git agent opens it via `canon/bin/item_worktree.sh open
      --branch issue_<N>-<slug>` BEFORE the item starts (parallel
      executors never share a tree or index); the worktree lives at
      <repo-parent>/.worktrees/<branch> and links `canon/` back to
      the shared deployed canon - mutable per-item state
      (`scope_whitelist`) therefore lives in the worktree's own
      `.canon_scope_whitelist.txt`, because concurrent items would
      race on one shared file; the ship gate refuses a worktree
      without it instead of silently falling back to the shared
      path. The worktree is removed together
      with the local branch by `item_worktree.sh close` once the
      item is merged or abandoned — remote branches/PRs remain the
      audit trail. Flow: scope plan > tests from G/W/T + code >
      green native run (project lint+tests+typecheck) > re-grounding
      (git status/diff --stat against the scope plan) > report in
      the profile format (RESULT/GATES/DECISIONS/OPEN). A report
      without literal run statuses is not accepted.
   e. The item judge verifies (p.5) — against the candidate COMMIT
      in the item worktree, not a dirty tree: the git agent commits
      the candidate state first, so untracked files can never hide
      from the diff and every verdict/envelope binds an exact SHA.
      Rework loops until verdict.
   f. A line in harness_log.jsonl via `canon/bin/harness_log.sh
      append`.
5. Deviations: non-contractual — inside a declared
   `delegated_decisions` axis or behavior-neutral — the executor
   decides itself, the report gives choice+alternatives;
   contractual — escalation (PLAN_DELTA > approve/reject); an
   undetermined point outside the delegated axes is a contract gap
   (p.4c), not a deviation.
6. PR assembly (all branch items done; a branch may carry several
   items — it is named by the primary issue, and `repository-agent`
   exports `ISSUE_NUMS` with all branch issues for
   `verify_constraints.sh`): integration run by the reviewer
   subagent (re-verifies each item's G/W/T + cross-item coherence)
   > rework loop UNTIL an APPROVE verdict: REQUEST_CHANGES or
   COMMENT with blocking findings — the executor fixes and goes for
   another pass. APPROVED is set only by the reviewer (self-approve
   does not count). The severity taxonomy is mechanical and
   identical for every review actor (judge, domain reviewers,
   aggregator): `[CRITICAL]` for any defect of correctness,
   contract violation, uncovered G/W/T scenario, `may_edit`
   breach, security or hygiene risk; `[UNCERTAIN]` when
   correctness cannot be proven from the artifacts (doubt without
   sufficient evidence - never softened into a lower tag);
   `[WARNING]` only for non-functional remarks where the
   implementation is provably conformant to contract and spec;
   `[MINOR]` for trivia. COMMENT/REQUEST_CHANGES carrying at least
   one `[CRITICAL]`/`[BLOCKER]`/`[UNCERTAIN]` = merge block;
   `[WARNING]` and `[MINOR]` never block a merge (otherwise the
   review loop degenerates into taste ping-pong and burns the
   escalation round budget). An APPROVE event carrying any
   `[CRITICAL]`/`[BLOCKER]`/`[UNCERTAIN]` finding is invalid and
   the gate rejects it. A PR is not
   merge-ready without APPROVE. If review rounds > 3 — complaint to
   the arch committee ("many review cycles, what to fix"), action
   per its decision. If the arch committee is called on one PR 3
   times and cannot clear the objections — stop, escalate to the
   developer. After APPROVE — the instance itself merges the PR via
   `repo_merge.sh` (every expected reviewer's APPROVE bound to the
   current head + required checks green, item without a manual_gate
   fragment). All publication commands
   (commit/push/PR/merge/release) run with an explicit
   expected_sha: the gate compares the revision the verdicts and
   envelopes are bound to with the operation's revision — merging
   "not what was reviewed" is blocked as stale_head. The gate
   includes the "blood signature": canonical
   `verify_constraints.sh` + `verify_worktree.sh` run on a detached
   worktree of the PR tree with `VERIFY_BRANCH`/`VERIFY_PR`/
   `ISSUE_NUMS` (the body's close/fix/resolve refs — each must
   exist and be Closes-linked, otherwise on the detached head the
   check is silently skipped) and `FRAG_ISSUES` (every `#N` in the
   body — the allowed set for the fragments' `issue:` field, so an
   epic PR can carry task fragments). There is NO separate
   human gate on release: under RoM the mechanical merge itself
   writes the release commit, tags `v<next>` and publishes the
   GitHub Release; a publication failure is returned as
   `release_failed` and finished off by re-running
   `repo_release.sh` (idempotent).

### Item type: exploration

A roadmap item before criteria freeze — for areas where acceptance
criteria cannot be formulated without researching the subject
(precedents: Android audio capabilities, transport quota signals).

- The output artifact is a research note: a section in the roadmap
  or `docs/research/<slug>.md`. Contains: what was checked, what
  was confirmed, what was refuted, open questions, a
  recommendation.
- The acceptance criterion is NOT code: a list of questions the
  research must answer, and the method bounds (documentation only /
  prototype allowed / specific APIs) — the `research_questions` and
  `method_bounds` fields in the item template.
- The exploration judge verifies completeness of answers to the
  declared questions and observance of method bounds — code is not
  evaluated.
- Dependent contract/implementation items get `depends_on` on the
  exploration item and do not freeze criteria until its verdict.
- Exploration writes no project code; prototype drafts — to
  `archive/` or scratch, not the main tree.
- Partner pre-consultation (p.4a) is not performed for exploration —
  the item itself is the reconnaissance.

## 5. Context packages (whitelists)

- **Executor**: its roadmap item block; contract read-only;
  may_edit/may_not_edit; acceptance command; 1-2 reference files;
  G/W/T scenarios; additional_acceptance_notes. Does NOT see: the
  whole plan, other modules, arch-committee reasoning.
- **Exploration executor**: `research_questions` + `method_bounds` +
  relevant docs/sources read-only. Does NOT see: the whole plan,
  other modules.
- **Item judge**: the item text with criteria and G/W/T; the
  contract path and its frozen hash (reads it from the repo itself
  and checks the hash against the sign-off envelope — anti-drift
  protection); the item diff; kb_rules excerpt <=2KB by domain tags
  (python-backend / ts-express / react-mobx; selected by table, not
  LLM). May call request_reference(topic) on root up to 2 times —
  root returns a slice of <=N lines <=M files.
- **Exploration judge**: `research_questions` + `method_bounds` +
  the research-note artifact. Verifies completeness of answers to
  every question and observance of method bounds — no diff, code is
  not evaluated.
- **Reviewer subagent (PR)**: PR URL + artefact_paths + contract
  path + item texts with criteria/G/W/T + kb_rules excerpt +
  previous verdict on re-review. Cap ~4KB without the diff. Must
  re-verify scenario coverage for every item. Read area — remote
  storage only (PR diff, checks, reviews): the working area and the
  uncommitted tree are not available to the reviewer.
- **Partner consultant** (no repo access): inline {item text, full
  contract, dependency summaries, question}. A structured answer is
  mandatory.
- **Resolver** (stuck review): item + contract + diff + objection
  history + read of the whole current repo (no cross-repo).
- **Reader agent**: path + expected result (verbatim range or
  digest). The report MUST include the attestation
  `{path, sha256, total_bytes, total_lines, covered_ranges,
  tail_anchor}`; the director verifies it with the
  `reader_digest.sh --verify` script — a self-report without
  verification is not accepted.
- **Any registered actor** additionally receives its capability
  token (issued by `cycle_log.sh register` at spawn) — the only
  thing that authenticates its `close` in cycle_log.

## 6. Escalation ladders

The single ladder form for any initiator:

initiator's question → own-level committee → architecture committee
(when the spec is unreachable or requires a change, with reasons) →
human → the answer travels back to the initiator along the same
chain.

The concrete ladders below are specializations of this form; the
"own-level committee" for the executor is the exec committee
(director + partner consultants via the gateway), for the director —
the arch committee, for the orchestrator — its partners committee.
Skipping a level without exhausting the lower one is forbidden.
The terminal point of any ladder is the human; their decision is
recorded as a decision envelope (§3).

### Dispute with the reviewer

The reviewer is right by default — the executor complies. Escalation
trigger: executor disagreement OR the reviewer marked the objection
`uncertain`. The question goes to all partners of the calling
committee at once. They agree — closed; they disagree — to the
developer. No sub-rungs.

### Stuck review

- Rounds 1-2: normal executor-judge loop.
- No agreement after round 2: resolver subagent (the last automatic
  attempt, NOT a counter reset). The resolver is a read-only,
  single-shot arbiter (`canon/agents/resolver.md`): it verifies the
  dispute package's integrity, rules each finding against the
  frozen contract (`SUSTAIN_WRITER`/`SUSTAIN_JUDGE`/
  `AMBIGUOUS_OR_CONFLICT`) and rolls up fail-closed —
  `UPHOLD_WRITER` | `UPHOLD_JUDGE` | `ESCALATE_ARCH`. It may run at
  most once per item cycle and its ceiling is the arch committee,
  never the human directly.
- Resolver failed to converge or round 3 expired: stop +
  classification:
  - repeating class of objections — wrong approach: upgrade
    exec-committee models, redo the item;
  - dispute over criterion meaning — spec uncertainty: arch
    committee refines the G/W/T;
  - heterogeneous minor objections — judge recalibration.

Escalation caps are uniform across the ladder: executor-judge > 2
rounds = resolver (not a counter reset); arch committee called on
one item 3 times without clearing objections = terminal escalation
to the developer (the step moves to `paused` and waits for the
human — this is the only terminal dispute state, there are no
further automatic levels).

### Risk flag (set in the roadmap at planning)

An item touching contract/schema files, auth/persistence boundaries
or >1 module — automatically two review verdicts from different
model families + developer confirmation before PR assembly.

## 7. Test conventions

- Stack: Vitest for TS/JS (ESM type:module, Node 24), pytest
  (+pytest-asyncio) for Python.
- Test file next to the source: `foo.test.ts` / `test_foo.py` per
  repo convention.
- The test name contains the scenario id verbatim:
  `it('[ITEM-12.GWT-3] returns 409 on duplicate')`. Mandatory rule;
  the coverage check greps ids from COMMITTED artifacts (the item's
  G/W/T scenarios are copied into `.changes/<slug>.md` or a
  docs/specs requirement) and, where a deployed
  `canon/roadmap.md` exists, from the item's roadmap block as an
  authoritative fallback — a scenario dropped from the fragment
  cannot downgrade the gate to a SKIP. A bare mention is not
  coverage: the id must sit inside an executable test definition
  (`def test_`, `it(`, `test(`, including parameterized
  `.each`/`.concurrent` forms) without a skip/TODO marker in its
  context — a suite container (`describe(`, `context(`), a comment
  outside a test body, or a skipped test does not count.
- One test = one G/W/T scenario.
- Mocks — at the contract boundary (HTTP clients, DB repositories
  via the module interface); a mock implements a type from
  contract.ts/py. Mocking internal calls of the code under test is
  forbidden.
- Tests and implementation — in one commit; on edits they are
  updated atomically.

## 8. Root discipline

- Root holds the high level: roadmap, statuses, contract index.
  Repo access exists (needed for task definition and answering
  questions).
- More than 2-3 files or repo-wide search — a read-only research
  subagent; only the digest enters root's context.
- Re-ground against roadmap.md before starting each item.
- All decisions go into roadmap.md immediately — root is
  restartable without loss.
- Root does not edit project code. A stuck review — resolver
  subagent, not self-repair.

## 8.1. Instance start — initialization protocol

Performed ONCE at instance start, before any work other than reading
`canon/RULES.md` and explicitly named files. These are entry
conditions, not per-step approval: after initialization only the
cycle gates apply (roadmap approval, contract sign-offs,
PLAN_DELTA, review disputes) — no intermediate confirmations
required.

Managed mode: for a managed instance "developer" in steps 1-4 and in
all blocking checkpoints = the orchestrator on the bus (`bridge ask`
/ question_answer reply); terminal human decisions are escalated to
the developer by the orchestrator itself — the worker never writes
to the developer directly.

1. ROLE: state your role and the expected result. If the
   instance's assignment is not obvious from the rules/context —
   clarify with
   the developer in one question.
2. SKILLS AND TOOLS: check the harness — `partner_info` on the
   bound partners, profiles in `canon/agents/`, skills in
   `canon/skills/`.
   If something critical is missing for the task — ask the
   developer what to substitute or where to get it. Silent
   substitutions are forbidden.
3. TASK: if the task statement was not given in the first message —
   ask the developer what the instance's task is and wait for the
   answer. Choosing the subject of work and analysing the repo
   "just in case" is forbidden. Code exploration is allowed only
   after the task statement — and only to the extent needed for the
   roadmap and clarifying questions.
4. ROADMAP: form roadmap.md only on the developer's explicit
   directive ("make a roadmap", "build a plan"). The task statement
   alone is not a roadmap directive — before the directive you may
   ask clarifying questions, you may not generate the document.

## 9. Step states, quota and observability

### 9.1. Reporting format (short invariant — in the agent-instance rules)

- Every authored text, including intermediate work-progress
  messages, starts with `YYYY-MM-DD HH:MM` and a `Question -` /
  `Task -` / `Answer -` marker.
- Work-progress messages additionally carry a status line:
  `Step: <what is being done> [<state>]`.

### 9.2. Step states (durable)

A step — a unit of work inside a task (roadmap item, reviewer call,
publication). States:

- `running` — in progress;
- `interrupted` — torn down without saving a resume point (turn
  crash, kill);
- `waiting_quota` — parked on an explicit model-limit error;
- `saved` — resume point saved, step not running;
- `paused` — stopped by an external command (HALT, manual pause,
  terminal escalation);
- `completed` — terminal: step finished with a result;
- `abandoned` — terminal: step dropped by decision (close/abandon).

Transitions (complete table; other pairs are invalid):

| from | to | trigger |
|---|---|---|
| - | running | step start |
| running | waiting_quota | explicit quota error with reset_at |
| running | saved | checkpoint save at turn end / limit T |
| running | interrupted | turn crash, kill, executor deadline |
| running | paused | HALT / manual pause / terminal escalation |
| running | completed | step completed with a result |
| waiting_quota | running | probe after reset_at succeeds |
| waiting_quota | waiting_quota | probe hits the limit again — re-park on new reset_at |
| waiting_quota | paused | fleet HALT (takes priority over quota) |
| waiting_quota | interrupted | killed by daemon kill-switch |
| saved | running | resume from the resume point |
| saved | waiting_quota | resume probe hits the model limit — park on the returned reset_at |
| saved | paused | HALT / manual pause arrives while the step is saved |
| saved | interrupted | kill-switch / unfixable failure |
| interrupted | running | resume of existing agent or fresh spawn from checkpoint |
| interrupted | paused | escalation without auto-resume |
| paused | running | pause lifted by external command |
| paused | completed | terminal decision confirming the step result |
| paused | abandoned | terminal decision (close/abandon) |

The instance must be able to answer a status request with the current
step's state, last-update time and transition reason.

### 9.3. Model-limit protocol (waiting_quota)

Trigger — ONLY an explicit quota/model-limit error with a reset
time (e.g. "Reached free model rate limit ... reset at HH:MM UTC").
`rpc_error`, `busy`, lease expiry, timeouts — NOT quota.

On trigger:

1. Record: error text, source (root / subagent / partner),
   `reset_at` in UTC, model/pool if known.
2. Save the step's resume point (what is done, what remains,
   artifacts/branch).
3. Move the step to `waiting_quota` until `reset_at`. The task does
   NOT fail, the retry budget is NOT consumed, lease recovery does
   not spawn a second executor.
   - **Managed mode** (a `bridge` daemon exists): park via
     `bridge quota-park` — the daemon owns the wait window and
     probes.
   - **Standalone mode** (no `bridge`): the instance cannot wait —
     local timers/sleep are forbidden. Write the park record to
     `canon/quota_park.json`
     (`{task, step, reset_at, checkpoint, raw_error}`), move the
     step to `waiting_quota`, report `reset_at` to the human and
     END the turn cleanly. On the next wake/turn the instance
     checks `canon/quota_park.json` first: before `reset_at` it
     stays parked (report and end again); after `reset_at` — one
     control probe, then resume the blocked step or re-park on a
     fresh `reset_at`.
4. Until `reset_at` wake messages into the instance are suppressed.
5. After `reset_at` — one control probe (a model preflight ping
   inside the instance before resuming the step):
   - success > continue exactly the blocked step;
   - limit again > update `reset_at`, repeat the wait cycle
     (without frequent retries).
6. Fleet HALT has priority: a quota reset does not resume stopped
   work.

Working model: the limit is bound to the model/pool; the call form
(root or subagent) does not matter — a probe at one point reflects
the pool. If observation refutes it (root passes, subagent fails) —
split the pools.

#### 9.3a. Limit on a subagent (incident 2026-11-17)

The wait window is owned by the instance only — a subagent cannot
and must not wait. An executor that hits the free-model limit and
keeps hanging without exit blocks the step forever — a real
incident. Two legs of the protocol:

Agent (see canon/agents/*.md): an explicit model-limit error with
a reset is a terminal signal for the run. The agent records a
checkpoint and IMMEDIATELY exits with a structured limit report
per its profile contract (`RESULT: QUOTA` + `QUOTA_RESET_AT`, or
failure_class=quota_limited) carrying the raw error text. Waiting,
retries and sleep inside the agent's turn are forbidden.

Calling instance:

1. The executor is called in BACKGROUND — the instance turn stays
   free for checkpoint ticks and parking. A foreground call that
   hangs on a limit blocks the instance turn and makes pp.2-4
   impossible; the foreground discipline from the rules applies to
   interactive (Desktop) instances where background occupies the
   turn-slot.
2. The agent returned a limit report -> the instance parks the live
   task:
   `bridge quota-park --task <id> --reset-at <UTC>`
   --checkpoint 'subagent=<agent_id>; <resume point>'
   --note '<raw error text>'. The daemon will send one control
   probe after reset_at — no own timer or sleep in the instance,
   they are forbidden.
3. The agent did not return and hangs -> on a checkpoint tick
   `read_subagent <agent_id> block=false`: the output tail is
   scanned for quota markers (rate limit / quota / 429 /
   resource exhausted + reset at|in). Marker found -> park per p.2;
   marker without reset -> park for the default window (900 s).
   The hung agent is killed AFTER parking:
   `bridge agent-kill --agent <agent_id>` — the daemon sends cancel
   directly to the instance's runtime, bypassing the mail queue (a
   STOP letter could wait while the instance picks up mail). A hung
   agent is NEVER "resumed" in hope of a report: resumption — only
   from a saved resume point.
4. After the control probe the instance resumes THE SAME agent:
   `run_subagent resume=<agent_id>` — the transcript is preserved,
   the step continues from the block point. Repeated quota error ->
   re-park on the new reset_at.
5. Resume impossible (agent dead, resume rejected, agent exited
   without a result) -> a fresh agent with the same context
   package + the saved resume point.
6. Parking consumes no retry budget and does not hand the task to
   another executor; machine semantics — canon/specs/quota.md.

### 9.4. Wake-up deduplication

An instance wake/nudge counts only if there is BOTH delivery
confirmation AND actual progress (new message/status/step
progress). N identical wakes without progress = 1 incident, not N
attempts. Do not poke a `busy` or quota-blocked instance again.

### 9.5. Responsibility

- The text invariant (9.1) — a short rule in `canon/RULES.md`.
- This specification is the canonical harness; the rules reference
  it.
- Neighboring canon specs: `quota.md` (quota), `gateway.md`
  (external access), `fleet.md` (topology, orchestrator, OOB),
  `glossary.md` (terms).
- Machine storage of states and deduplication — the bus
  (`bridge`, task/step states, reset_at, suppress-window).

## 10. What is excluded (cut deliberately)

Mutation testing, a separate LLM-gate in
CI, DDD-tiered review, ephemeral environments, mandatory
C4/sequence diagrams, Enrich/Research phases as separate stages,
a pre-commit hook on FROZEN contracts, a ban on root reading code,
context token caps, live success metrics.
