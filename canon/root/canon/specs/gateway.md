# Gateway: unified LLM gateway

Specification of external model access. Part of the canon, at the
orchestration-instance and shared-loop level (see `fleet.md`, terms
— `glossary.md`).

## 1. Single egress point

- All external LLM calls (partner consultants, external architect,
  second-family independent reviewer, other providers) go ONLY
  through the gateway. A direct external-model call from an agent
  instance (orchestrator, director, executor, designer, judge,
  reviewer, etc.) is forbidden.
- Provider keys and quotas belong to the gateway, not to agent
  instances. An agent instance has no access to provider
  credentials.
- The gateway is an accepted single point of failure (a deliberate
  human decision; a lightweight service with minimal state, restart
  without journal loss: the journal lives in STATE, not in the
  gateway process).
- Partners are addressed by canonical ROLE, not vendor name: the
  role registry (`config/partners.json`) fixes the committee,
  profile and tier per role; the concrete model binding is a
  project/deploy setting (`project.json` → `partners`).

## 2. Call profiles

| Profile | Purpose | Controls |
|---|---|---|
| `Audit` | external-architect audit, second-family verdict, dispute arbitration | iteration counter, immutable verdict journal in STATE, verbatim archive of request/response |
| `Consult` | working partner consultations (arch/exec/orchestrator committees) | budget limits, light tracing (metadata + digest) |

- Deliberation between partners runs as bounded conflict-directed
  rounds (harness.md §2): round 1 is blind; later rounds carry
  only counterarguments against the callee's own position, never
  a consensus framing. The director assembles every packet;
  partners stay stateless and never exchange directly. The call
  round is journaled (`partner_call.sh --round`).

## 3. Call classification — from state, not from the claim

The call class is derived deterministically from STATE and the
callee type; the label the initiator attached to its request does
not change the class.

- An open dispute about an item/artifact in STATE → a call on that
  context is automatically `Audit` regardless of the claimed label.
- Calls to the external architect and to the second model family —
  always `Audit`.
- Other partner calls — `Consult`, but also journaled.
- A frequency anomaly of `Consult` calls on one item (repeated
  consultations on the same context with no recorded dispute) is a
  signal in the journal; it may be read as an Audit-bypass attempt
  (verdict shopping at the classification boundary).
- The initiator cannot lower a call's class. Raising
  Consult→Audit is performed only by a gate/the human.

## 4. Verdict integrity

- A verdict (the answer to an Audit call) is written into the STATE
  journal BEFORE it is returned to the initiator. Neither the
  request's author nor the orchestrator filters or rewrites the raw
  verdict.
- Packages to the external architect are assembled by the subject
  owner (worker — for its product, orchestrator — for canon); the
  gateway sanitizes (secrets, sizes) and archives a verbatim copy
  of the package and the answer.
- The result is returned to the initiator as a sanitized registry;
  trigger events (canon, unbound calls, iteration-limit exhaustion,
  open dispute) are mirrored to the addressees per instance rules.

## 5. Limits

- `Audit`: hard iteration counter per audit; exhaustion — a
  terminal signal (escalation path, not auto-renewal). The audit key
  defaults to a deterministic hash of the audited payload, so the
  same artifact shares one budget; a global daily cap
  (`audit_daily_max_total` in policy.json) backstops key spraying.
- `Consult`: budget limits per item/period; exhaustion — refusal
  with failure_class=quota_limited or parking per the quota
  protocol (`quota.md`), with no silent profile upgrade.
- The gateway state is integrity-critical: counters and the
  verbatim journal live in `canon/gateway.db` (SQLite,
  `journal_mode=WAL`, `synchronous=FULL`). Quota check+increment
  is a single atomic transaction that commits BEFORE the backend
  call - a transaction is never held open across the network, and
  concurrent callers can never lose or double-spend an increment.
  Because the increment lands before the call, a caller killed
  mid-flight (SIGKILL/OOM - no finally-block runs) would orphan the
  spend: the `inflight` table therefore records
  `{call_id, pid, ts, keys}` before the network hop and clears it after;
  every call first reaps rows whose pid is dead and refunds their
  increments in ONE `BEGIN IMMEDIATE` transaction - a row is deleted
  and its increments returned atomically, so two concurrent callers
  can never refund the same orphan twice - so a hard-killed
  caller's quota is restored by the next run instead of leaking.
  Rows also carry a TTL: an inflight row older than the call
  timeout +60s (600s) is reaped even when its pid is alive -
  pid reuse can put a foreign process on a dead caller's pid,
  and the quota must not wait for it.
  An unreadable/corrupt store is a fail-closed refusal until
  repaired, never a silent reset. The journal table is
  append-only: no UPDATE/DELETE path exists in `gw_store.py`.
  A legacy `gateway_counters.json` is migrated once on first use
  and renamed `.migrated` so it cannot be replayed.
