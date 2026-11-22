# CCSDD Methodology — Committee Cycle Spec-Driven Development

[Русская версия → ../ru/methodology.md](../ru/methodology.md)

## Name

**CCSDD** — *Committee Cycle Spec-Driven Development*: a spec-driven
methodology organized as a **cycle of committees** — an architecture
committee that designs, an executive committee that builds, and
reviewers that belong to neither.

Why this name: it positions the method inside the SDD family while
stating both differences — the actors executing the specs are
probabilistic LLM agents (every SDD assumption gets a *mechanical*
gate behind it, not a prompt instruction), and authority is split
between committees plus out-of-committee reviewers (maker–checker),
not concentrated in one assistant.

## The problem it solves

Classic process models (SDLC, Scrum) and the newer spec-driven tooling
(SDD/Spec Kit, OpenSpec) all assume the implementer is a disciplined
human or a deterministic pipeline. An LLM agent is neither: it can
write excellent code *and* quietly edit a protected file, close its own
task, "approve" its own work, or plausibly report on things it never
did.

Hence the base axiom of CCSDD: **every agent action is untrusted
output that must pass a deterministic check before it becomes state**.
Everything else in the methodology follows from that axiom.

## Our approach

### 1. Untrusted actors + deterministic gates

Every rule that matters exists in two forms: text in a spec/rules file
**and** an executable check. An agent instance cannot "decide" to
skip lint, commit a protected path, or merge without verdicts — the
corresponding
exec calls are denied in `config/policy.json`, and state transitions
are performed only by `canon/bin/` scripts (bash + git + gh,
deterministic, fail-closed). Prompts and role profiles describe
responsibilities; enforcement lives in gates.

### 2. Two-committee structure + review outside committees

- **Architecture committee** — the root director (the main agent
  instance in the repository) + partner consultants
  (architect-partner, product-partner — canonical roles bound to
  top-tier models) + the human arbiter. Designs
  the roadmap and each item. Never edits project code.
- **Executive committee** — the executor subagent (`code_writer`) +
  consultants (design-partner, product-partner — workhorse tier).
  Implements one roadmap item inside a scope whitelist.
- **Reviewers — outside both committees**: judge, reviewer subagent,
  resolver, reader. Verdicts are issued only against fixed artifacts
  and the frozen contract; no committee judges its own output.

Separation of duties is mechanical, not organizational: the executor
has no git in its allowed execs, the git agent has no merge right, and
the merge gate merges only on reviewer verdicts bound to the current
head sha — never on an instance's say-so.

### 3. The director instance (event-driven)

Root is one long-lived agent instance per repository: the single
writer of plan and statuses; it spawns role subagents with narrow contexts
(whitelist packages — item text, read-only contract, file slices),
collects their reports and verdicts, and keeps the journals. The
subagent's narrow context is itself a mechanism: it physically cannot
see more than its package, and its `request_reference` back to the
director is bounded to a slice of `≤N lines, ≤M files`.

### 4. The contract as a frozen object

Every roadmap item rides on a contract: G/W/T scenarios, an editable
path whitelist, a risk flag, a success command. Lifecycle
`draft → judged → signed_off`: the judge verifies the draft, the human
signs, the contract freezes — its SHA-256 goes into the envelope.
From then on the judge checks artifacts **against the frozen bytes**,
and contract-to-reality consistency is re-verified at item spawn
(stale → re-judge or PLAN_DELTA — never "fix it on the fly").

### 5. The human as gate holder, not observer

`👨‍💻` gates: roadmap approval, per-item contract sign-off (or batch
elaboration of the first N — §2a), escalation and PLAN_DELTA
decisions, canon publication. The merge itself is objective —
reviewer APPROVEs + green checks + `expected_sha` — unless a
`.changes` fragment declares `manual_gate: true`, which parks the
merge for an explicit developer decision. A decision is recorded as
an **envelope**
`{verdict, artifact_sha, sig, signed_by, ts}` — written outside the
LLM context, signed with a key kept outside the workspace, and
mechanically verified by consumers against the artifact hash. A
"verbal" approval is impossible: the gate checks the envelope, not
chat text.

### 6. Per-item verification chain

`executor (pre-code interrogation → code+tests → green run) → judge
(≤3 rounds against the frozen contract) → reviewer subagent (separate
account, remote-storage-only reads, verdict unfiltered by the
director) → git agent (candidate commit with explicit sha) → hygiene
(diff scan, attribution, `.changes` fragment) → merge gate (isolated
worktree re-verification + `expected_sha` + every expected reviewer's
APPROVE on the current head + required checks green) →
Release-on-Merge (version computed from `.changes/`).`

For `risk: high` — verdicts from two independent model families plus
human confirmation before PR assembly.

### 7. Bounded loops and the escalation ladder

Rework is bounded: >3 dispute rounds with judge/reviewer → resolver →
item stop, not endless thrash. Ambiguity climbs the ladder: question →
level committee → architecture committee → human (terminal); skipping
a level is forbidden. The mandatory **pre-code interrogation** makes
the executor record assumptions and criterion readings before writing
code — an empty interrogation is itself a signal to the judge.

### 8. Integrity of the methodology itself

The methodology is an artifact under control too: canon deploys
verbatim per `MANIFEST.json` with a sha256 map (drift is caught by
`check_setup.sh`), it is deployed not tracked (gitignore block), and
a per-repo **canary** in the `RULES.md` tail proves the instance rules
were not truncated. Canon changes are single-writer through
`canon_pub.sh` with a signed human envelope; LLM self-modification of
the canon is forbidden. The actor registry (`actors.json` +
capability tokens) separates role powers: a `close` operation is
authorized by a token, not by a job title in text.

## Core primitives

| Primitive | What it is |
|---|---|
| **Roadmap item** | The unit of work; one autonomous task with an artifact. |
| **Contract** | Per-item acceptance spec (G/W/T, whitelist, risk flag). `draft → judged → signed_off`, frozen by SHA-256. |
| **Decision envelope** | Human decision bound to the artifact hash — written outside the LLM context. |
| **Gate** | A deterministic script: `check_setup`, `verify_constraints`, `hygiene_check`, `repo_merge`, `canon_pub`. |
| **Verdict journal** | `cycle_log`, `harness_log`, verdicts — the auditable trail. |
| **Canary** | Per-repo token at the `RULES.md` tail; absence ⇒ rules truncated ⇒ halt. |
| **Canon** | The methodology itself as versioned, hash-pinned, single-writer content. |

## Inheritance map — what we take from where

### From SDD (Spec-Driven Development: Spec Kit, Kiro, etc.)

**Taken:** spec-first workflow; acceptance criteria as executable
Given/When/Then scenarios; the spec, not the code, is the reviewed
artifact.

**Changed:** in SDD the human reviews a spec document — in CCSDD the
spec becomes a *frozen object*: sign-off writes the contract SHA into
a signed envelope, judges verify artifacts *against the frozen bytes*,
and implementation may not start on an unsigned contract. Spec drift
after sign-off is a `PLAN_DELTA` escalation, not an edit.

### From OpenSpec

**Taken:** change-as-object (a change proposal with its own
lifecycle), explicit delta handling, versioned change artifacts —
mirrored by our contract lifecycle and `.changes/<slug>.md` release
fragments (changesets convention).

**Changed:** OpenSpec trusts the assistant to follow its conventions;
CCSDD replaces convention with gates — the same ideas are enforced by
`verify_constraints.sh`, `hygiene_check.sh`, and the merge gate.

### From SDLC

**Taken:** the phase skeleton — plan → design → build → verify →
release — mapped onto the item lifecycle with explicit entry/exit
conditions per phase.

**Changed:** no big-upfront phases for the whole product; phases run
per *roadmap item*. The only whole-product gate is roadmap approval
itself.

### From Agile / Scrum

**Taken:** roadmap ≈ backlog, items ≈ issues, the human ≈ product
owner with final say, backlog label for unprioritized ideas.

**Rejected:** the ceremony layer (standups, sprints, estimation
rituals). Coordination overhead is replaced by event-driven gates and
the verdict journal — an agent does not attend meetings.

### From GitOps / IaC

**Taken:** desired-state-in-manifest deployment (`MANIFEST.json` +
sha256 map), *deployed-not-tracked* canon, release fencing via
`canon-v<version>` tags, drift detection by hash comparison.

### From supply-chain security (SLSA / in-toto / Sigstore patterns)

**Taken:** hash-pinned content, attestation-style envelopes binding a
decision to an artifact digest, per-deploy canary tokens, HMAC-signed
human approvals with the key held outside the workspace.

### From financial controls (four-eyes / maker–checker)

**Taken:** separation of duties as a hard boundary — the writer cannot
commit (no git in the exec allowlist), the committer cannot merge, the
merger requires every expected reviewer's APPROVE bound to the head
sha, and reviewers sit *outside both committees* so no committee
judges its own output.

### From code-review / branch-protection practice

**Taken:** the merge gate is branch protection made mechanical —
detached-worktree re-verification + verdict presence + `expected_sha`
freshness + required checks green, plus a reviewer account that the
director cannot filter.

## What we deliberately do NOT take

- **Waterfall's sequential rigidity** — items run incrementally and
  independently gated; roadmap replans are normal.
- **Prompt-based trust** — every rule that matters exists as a script,
  a hash check, or a denied exec; prompts carry only what gates
  already enforce.
- **Self-certification** — no agent marks its own work done, closes
  its own task, or approves its own merge.

## Trust model (what is enforced where)

Three enforcement levels, honestly distinguished:

- **Mechanical (outside the agent's reach):** branch protection,
  required reviews and check status live on GitHub — the agent has no
  write path to them. Human decision envelopes are signed with a key
  kept outside the workspace. These are hard boundaries.
- **Mechanical but workspace-anchored:** the integrity manifest
  (`canon_manifest.json` sha map, pinned adapter hooks), the scope
  whitelist and `project.json` are checked at Gate 0 and on every
  commit — but they sit in a workspace where an exec-capable agent
  could rewrite them. They **detect** drift reliably; they cannot
  **prevent** a determined in-workspace edit. Treat their green
  result as "unmodified since last verified", not "unmodifiable".
- **Convention:** prompt-level obligations (report formats,
  interrogation, marker discipline). They exist to be audited, not to
  be trusted — every convention is paired with a mechanical check
  where it matters.

Physical isolation of agents (the OOB/envelope layer) is the planned
hardening for workspace-anchored items and is outside this drop.

## Roles at a glance

```
👨‍💻 DEV human ──► gates: roadmap, sign-off, manual_gate, escalations
🧭 ROOT director ──► plan, contract drafts, spawns roles, never commits
👷 CW executor ──► code+tests inside whitelist, pre-code interrogation
⚖️ JDG judge ──► verdict vs frozen contract only
🔍 RVW reviewer ──► remote-storage-only review, unfiltered by ROOT
🤝 RES resolver ──► bounded disagreement rounds → stop/escalation
🔀 GIT / 🏁 RA / 🧹 HYG ──► candidate commit → hygiene → merge gate → release
📖 RD reader ──► file attestation {path, sha256, ranges, anchor}
🛰️ PRT partners ──► consultations via gateway, separate model family
```

Diagrams: [item lifecycle](diagrams/item_lifecycle.svg) ·
[cycle structure](diagrams/cycle_structure.svg)

## Lifecycle of one roadmap item

`plan → 👨‍💻roadmap approve → issues → (optional §2a batch contracts) →
contract: draft→judged→👨‍💻sign-off(sha) → pre-consult → spawn → pre-code
interrogation → code+tests → judge rounds ≤3 → reviewer → GIT commit →
HYG → merge gate (isolated copy + expected_sha + reviewer verdicts +
green checks; manual_gate fragment → 👨‍💻) → release`

Escalation ladder: question → level committee → architecture committee
→ human (terminal). Bounded rework loops stop the cycle instead of
thrashing.
