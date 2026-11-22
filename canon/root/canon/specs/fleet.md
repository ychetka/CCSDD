# Fleet: orchestration instance and fleet

Topology specification: orchestration instances, the shared loop,
orchestrator replacement, the out-of-band loop. Terms —
`glossary.md`; external access — `gateway.md`; worker cycle —
`harness.md`.

## 1. Orchestration instance

An orchestration instance = the state-isolation boundary:
1 orchestrator + 1 bus + 1..K workers + its own STATE. Instances
in the system: [1..M]. There is no meta-orchestrator: instances
are isolated and do not dispatch each other.

- One instance — one active orchestrator. Two orchestrators on
  one bus is a forbidden case; globally, several
  orchestrators exist (one per instance).
- The orchestrator role on the bus is registered CAS with a lease
  (TTL) and an epoch: writes to instance state are accepted only
  from the holder of the current epoch — a stale (zombie)
  orchestrator cannot write.
- Addressing — the logical role, not the instance-id: worker
  messages go to the instance's orchestrator role, not to a
  concrete sid.

## 2. Orchestrator replacement

The orchestrator is a replaceable agent instance, not a context
accumulation point.

- The transport daemon watches the orchestrator (heartbeat+lease,
  context window, kill-switch) symmetrically to workers.
- On death/hang/context exhaustion the out-of-band loop (OOB)
  performs a cold respawn: the new instance is hydrated from the
  instance's STATE while workers are parked.
- Exhausting the respawn budget — an alert to the human (the
  terminal path); there are no further automatic levels.

## 3. Interaction journal and relationship context

- The instance's STATE includes an interaction journal — a durable
  history of communications and decisions between the orchestrator
  and the instance's workers (the relationship context). The
  journal is kept per instance, not per worker: the relationship
  is "orchestrator ↔ instance".
- The orchestrator must continuously write the rationale of
  decisions made into the journal — otherwise a cold respawn loses
  the "why" while restoring only the "what".
- The journal is a separate context, not part of the
  orchestrator's main context. A permitted variant: a dedicated
  communicator subagent outside the orchestrator's context reads
  the instance journal and hands the orchestrator structured
  decisions/summaries — the orchestrator does not absorb the
  whole correspondence stream.

## 4. Fleet registry (FLEET)

- Shared storage of records about agent-instance domains and
  orchestration instances.
  Every record is marked with the owner instance (`instance`) and
  carries the registration epoch (`epoch`).
- An instance writes its own records and reads others'. The canon
  owner mark (`canon_owner`) is assigned only by the human —
  self-proclamation is impossible.
- FLEET is a topology registry, not task state: step states live
  in the instance's STATE and in the bus.

## 5. Out-of-band loop (OOB, Runtime Root of Trust)

A non-LLM component outside agent instances: the only mechanism
of cold start and recovery.

- Bootstrap and break-glass entry are performed only by the human —
  no agent instance initiates OOB.
- Duties: initializing storages and the bus, starting the gateway
  (keys and limits bypassing LLM), instance spawn/respawn,
  freeze/restore of STATE, rotation/protection of root secrets,
  emergency backup control of a worker.
- OOB makes no product decisions and does not write to working
  repositories.

## 6. Canon: publication and rollout

- Canon is single-writer: only the owner instance writes it (the
  `canon_owner` mark in FLEET, assigned by the human). The rest
  read the active version and may initiate an RFC.
- Canon drafts live in the owner's separate canon work area;
  publication — only through the canon publication loop (see
  `canon_gate.md` and gate decisions in `harness.md`).
- The canon version is pinned per worker cycle: the worker records
  which canon version the cycle ran on; canon drift vs the pinned
  version — an auditable event.

## 7. Dogfooding

- The platform (including the bus and harness) is developed as a
  regular project in a worker: generation N-1 of the process
  builds N.
- Switching the live loop to a new generation — only by the human,
  through the out-of-band loop with rollback; protective loops
  carry a permanent risk:high flag per `harness.md` §6.
