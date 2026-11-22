# Glossary: architecture terms

Part of the canon. The single dictionary of terms for all specs and
for packages sent to external partners.

Mandatory for inclusion in every package to the external architect —
the partner is stateless and does not know our definitions.

## Topology

- **Orchestration instance** — the scaling unit of the system: a
  bundle of "1 orchestrator + 1 bus + 1..K project workers". The
  state-isolation boundary: each instance has its own bus, state
  and orchestrator-role lease. Instances in the system: 1..M.
- **Fleet** — all instances together.
- **Bus** — the regular transport between the orchestration
  instance's agent instances: a reliable queue + mailboxes + a
  delivery daemon. Implementation: an agent-instance bridge (may
  be different).
- **Out-of-band loop (OOB)** — management infrastructure outside
  the bus: bootstrap, instance spawning, tokens, canon rollout,
  recovery. The Runtime Root of Trust — fully deterministic, no
  LLM.
- **Cell** — deprecated synonym for "orchestration instance", do
  not use.

## Actors and roles

- **Agent instance** — one isolated LLM context with its own
  identity, bound to one role at a time. The unit of context
  isolation and accountability: ROOT/ORC are long-lived
  instances; CW/JDG/RVW and other worker roles are spawned
  instances; partner calls are stateless and are NOT instances.
  An instance runs in managed or direct mode. **"Session" is a
  deprecated synonym** — it named a runtime mechanism, not the
  trust boundary; do not use.
- **Human developer (DEV)** — the highest arbiter: approval of the
  plan, contracts and canon, plan changes, high-risk confirmation,
  canon publication, manual_gate decisions, resolution of
  disagreements and escalations.
  Maximally involved at design, minimally at implementation.
- **Orchestrator (ORC)** — the instance-management agent
  instance: task assignment, domain routing, exceptions. Does not
  read product code. A replaceable instance (stateless over
  STATE). One per bus — role lease CAS + TTL + epoch.
- **Project director (ROOT)** — the worker agent instance: plan
  author, spawns roles, performs no git operations itself. Short
  event-driven turns, background executors, checkpoints.
- **Artifact executor (CW)** — a worker role: writes artifacts in
  the work area against a file whitelist, a green native run is
  mandatory, the contract is immutable to it.
- **Item judge (JDG)** — verdicts only on fixed artifacts (diff,
  checks, frozen contract), never on self-reports.
- **Reviewer (RVW)** — separate account, publishes the verdict
  directly to the storage — the director does not filter it.
- **Resolver (RES)** — the last round of review-disagreement
  settlement; does not reset the rounds counter.
- **Reader (RD)** — reads sources in full and issues a coverage
  attestation (hash, ranges, anchor).
- **Commit agent (GIT)** — local fixation: a git commit or a
  snapshot with an immutable hash.
- **Publication agent (RA)** — the project-type adapter:
  PR/changeset, checks, merge/apply, release + history + metadata.
- **Auto-review (AUTO)** — a storage bot on publication trigger.

## Committees and external actors

- **Architecture committee** — plan, item types, contracts,
  acceptance criteria, risk flags, disagreements. Director (author)
  + partner consultants (co-authors) + human (arbiter).
- **Executive committee** — implementation of one item: executor +
  partner consultants.
- **Review** — outside the committees: judge, reviewer, auto-review,
  resolver.
- **Partner consultants (PARTNERS)** — external stateless models:
  arch-committee co-authors, exec-committee consultants, the
  orchestrator committee, dispute arbiters.
- **External architect (ARCH)** — external stateless auditor,
  reachable only through the unified gateway.
- **Independent reviewer (CR)** — the second model family,
  mandatory on high risk before publication.

## Infrastructure

- **Unified LLM gateway (PROXY)** — the single egress point to all
  external LLMs: keys, quotas, two-way filtering, immutable verdict
  journal. A deliberately accepted single point of failure.
  - **Audit profile** — audit, arbitration, 2nd family: iteration
    counter, completeness barrier, verdict journal.
  - **Consult profile** — working consultations: budget limits.
  - **Call class** is determined by state (open dispute → Audit),
    not by the caller's label.
- **Hygiene gate (HYG)** — deterministic filter before any
  publication: attribution, secrets, language, paths, format.
  Fail-closed, rejects rather than fixes.
- **Transport daemon (DAEMON)** — supervision of workers AND the
  orchestrator: heartbeat + lease, context window, quota, wake-ups,
  recovery, requeue, checkpoints, agent stop bypassing the queue.
- **Canon publication loop (CANON_PUB)** — publication of canon
  releases: commit, PR, merge gate, manifest, changelog, validation
  (hygiene, checksums, harness read limit).
- **STATE** — the instance's persistent state: iterations,
  completeness barrier, escalations, verdict journal, human
  decision envelopes, interaction journal.
- **Fleet registry (FLEET)** — the source of truth for agent
  instance domains and orchestration instances. Records are
  marked by the owner instance;
  the canon owner is assigned by the human.

## Mechanisms and artifacts

- **Canon (CANON)** — the remote repository of immutable releases
  of the system's rules: version, manifest, checksums, harness,
  agent profiles, gate scripts, cycles, project-type profiles.
- **Harness** — the rules/profiles/gate-script set deployed to an
  agent instance from canon.
- **Project-type profile** — a declarative binding from canon:
  which artifacts, which native run, which agents and gates.
- **Work area (WS)** — the worker instance's local filesystem.
- **Artifact storage (REPO)** — a remote repository or versioned
  store: code, specs, diagrams, roadmap, backlog, releases.
- **Frozen contract** — the item's acceptance criteria fixed by
  hash BEFORE the executor starts; change — only through
  invalidation and escalation.
- **Mandatory interrogation** — the exec-committee artifact before
  code starts: a structured record of assumptions and ambiguities;
  ambiguities climb the escalation ladder.
- **Decision envelope** — an immutable record of the human verdict
  in STATE (verdict + artifact hash + verbatim), checked
  mechanically by agents, not an LLM-mediator's text.
- **Completeness barrier** — the cycle is complete only when the
  code state converges with the canon version and the defect
  registry.
- **Escalation ladder** — question → level committee → arch
  committee (spec unreachable) → human; the answer returns to the
  initiator.
- **Managed mode** — the worker does not write to the human:
  questions go to the orchestrator, decisions arrive as envelopes.
- **Direct mode** — the worker confirms gates with the human
  directly; mutually exclusive with managed.
- **Role lease** — CAS registration of the orchestrator on the bus
  with TTL and a monotone epoch against zombie instances.
- **Interaction journal** — the relationship context
  "orchestrator ↔ instance"; loaded before any instance decision.
- **Verdict shopping** — an anti-pattern: re-asking the model until
  the wanted verdict; excluded by the verdict journal and
  deterministic call classification.
- **Dogfooding** — the platform is developed as a regular project
  in a worker (N-1 → N); switching the live loop — only by the
  human through the out-of-band loop.
