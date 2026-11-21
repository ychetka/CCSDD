# Gateway: unified LLM gateway

Specification of external model access. Part of the canon, at the
orchestration-instance and shared-loop level (see `fleet.md`, terms
— `glossary.md`).

## 1. Single egress point

- All external LLM calls (partner consultants, external architect,
  second-family independent reviewer, other providers) go ONLY
  through the gateway. A direct external-model call from an LLM
  session (orchestrator, director, executor, judge, reviewer, etc.)
  is forbidden.
- Provider keys and quotas belong to the gateway, not to sessions.
  A session has no access to provider credentials.
- The gateway is an accepted single point of failure (a deliberate
  human decision; a lightweight service with minimal state, restart
  without journal loss: the journal lives in STATE, not in the
  gateway process).

## 2. Call profiles

| Profile | Purpose | Controls |
|---|---|---|
| `Audit` | external-architect audit, second-family verdict, dispute arbitration | iteration counter, immutable verdict journal in STATE, verbatim archive of request/response |
| `Consult` | working partner consultations (arch/exec/orchestrator committees) | budget limits, light tracing (metadata + digest) |

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
  terminal signal (escalation path, not auto-renewal).
- `Consult`: budget limits per item/period; exhaustion — refusal
  with failure_class=quota_limited or parking per the quota
  protocol (`quota.md`), with no silent profile upgrade.
