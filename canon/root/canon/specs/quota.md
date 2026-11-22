# Quota - waiting_quota step state

Rate-limited work parks at step granularity: the task keeps its
lifecycle status and lease while `step_state=waiting_quota` records
that the current step is blocked on a provider quota reset.

### Requirement: quota park is orthogonal to lifecycle

A task parked on quota SHALL keep its live `status` and its
claimant's lease - `step_state='waiting_quota'` records the blocked
step without spending attempts or freeing the task to other
claimants.

#### Scenario: parked task is invisible to recovery and claims

- **WHEN** a live task carries `step_state='waiting_quota'`
- **THEN** `recover_stale`, dead-worker requeue and lease auto-renew
  skip it
- **AND** claim/dispatch CAS paths refuse to promote it before the
  reset

### Requirement: auto-park needs an explicit limit signal plus reset

A `bridge event`/`bridge notice` body SHALL auto-park the reporting
task only when it carries an explicit rate-limit marker AND a
parseable reset time; generic errors never park. A wake or
dispatch-prompt transport error carrying the same marker parks the
affected live task the same way; on the transport surface a marker
without a reset parks for a bounded default window (900s), which the
quota pass re-probes at its end.

#### Scenario: rpc_error, busy, timeout, lease-expired never park

- **WHEN** a report or transport error carries no quota marker
- **THEN** no park happens
- **AND** a self-report marker without a reset records the signal but
  requires a manual `bridge quota-park` to park

#### Scenario: transport-surfaced rate limit parks the live task

- **WHEN** a wake or prompt `rpc_error` body carries a rate-limit
  marker and the instance has a live task
- **THEN** the task parks as `waiting_quota` with the parsed reset -
  or the default window when the marker names none - instead of
  burning the retry streak or finishing the task failed
- **AND** the instance drops out of every wake leg until that reset

### Requirement: every real park is durable-journaled with its marker

Every successful real (non-defer) park SHALL commit a `quota_park`
`decision_events` row in the same transaction as the CAS, carrying
the reset window, the park source and the original marker text - the
audit must always be able to explain a later unpark/probe cycle.
Deferral re-parks write no second row (their own
`quota_probe_deferred` events carry the cycle) and SHALL preserve the
original `quota_note` so the marker stays readable on the row for the
whole episode.

#### Scenario: postmortem sees the park's why

- **WHEN** any path (wake transport, dispatch pump, self-report,
  manual `bridge quota-park`) parks a live task
- **THEN** a `quota_park` event row exists naming the task, the reset
  window, the source and the marker text
- **AND** a deferred probe re-park leaves `quota_note` untouched

#### Scenario: quota signal without a live task journals only

- **WHEN** a wake error carries a quota marker but the instance has
  no live task
- **THEN** the signal is journaled as `quota_signal_seen` and
  ordinary `rpc_error` handling applies

### Requirement: park state moves by CAS, never by blind write

Every `step_state` transition (park, clear, re-park, release)
SHALL be a compare-and-swap on the expected prior state - a plain
timestamp comparison plus an unconditional write can clobber a
concurrent transition (e.g. a manual `quota-park` landing between
the sweep's read and its write). The CAS failure path SHALL be
logged as `quota_cas_conflict` and the operation retried against
the re-read row or abandoned, never forced.

#### Scenario: concurrent manual park wins deterministically

- **WHEN** the quota pass sweeps an expired park while a manual
  `bridge quota-park` lands on the same row
- **THEN** exactly one transition commits; the loser observes the
  CAS conflict and re-evaluates the actual stored state

### Requirement: clear-rearm-probe is one atomic transaction

When `quota_reset_at` passes, the daemon quota pass SHALL clear the
park, re-arm the lease for a full window and enqueue/send exactly
one control probe to the instance INSIDE the same transaction - a
cleared park without a delivered probe must not be observable.
Probe delivery paces on a dedicated pacing budget independent of
the ordinary wake cooldown - a instance whose undrained mail keeps
the wake cooldown armed SHALL still receive its control probe.
When the probe turn and a pending mail-drain fall in the same
pass, the probe fires once and the turn drains the mailbox - the
daemon SHALL NOT issue a second wake for the same mail.

The control probe is a daemon-owned probe of the step's model
pool: it asks the instance to run the blocked step's smallest
preflight on the same model tier. Its outcome is binary:

- probe succeeds -> the instance resumes exactly the blocked step;
- probe hits the limit again -> the instance reports the marker and
  the task re-parks by the new reset (full park cycle, not the
  short defer window used for transport failures).

Probe TRANSPORT failure (no lockfile, pacing, rpc_error without a
quota marker) is a different class from a probe that reached the
model and found it still limited - transport failure uses the
defer path below.

#### Scenario: undeliverable probe re-parks, bounded

- **WHEN** the released task's probe cannot be delivered (no
  lockfile, pacing, transport error)
- **THEN** the task re-parks for a short defer window
- **AND** after the per-episode defer limit the park releases to the
  ordinary lease lifecycle with a durable `quota_probe_gave_up` event

#### Scenario: probe that finds the pool still limited re-parks fully

- **WHEN** the delivered probe returns an explicit quota marker
  with a reset time
- **THEN** the task re-parks until that reset as a new park cycle
  (defer budget untouched, `quota_park` event names
  `quota_source=probe`)
- **AND** a repeated quota outcome after resume is never treated as
  task progress or successful completion

#### Scenario: mail-wake cooldown does not starve the probe

- **WHEN** a instance is woken for pending mail in the same daemon pass
  that its expired park sweeps
- **THEN** the control probe still fires - wake pacing must not
  consume the probe's delivery budget

### Requirement: give-up on a busy owner holds and escalates

When the defer limit is reached and the owning instance is verifiably
mid-turn per instance/list, the task SHALL NOT release to the lease
lifecycle - releasing there folds a probe-delivery problem into a
worker failure. The park instead re-arms for a bounded hold
(`QUOTA_BUSY_HOLD_SECONDS`, default 3600s) and the
first give-up per episode escalates once to the orchestrator as a
`[QUOTA_PROBE]` notice (notify-send fallback); repeat give-ups
re-hold without re-alerting. Holds are bounded at
`QUOTA_BUSY_HOLD_LIMIT` (3) per episode - a permanently-busy
(wedged) turn cannot park its task forever after a single
escalation. An owner that cannot be verified busy, or whose hold
budget is spent, keeps the release contract.

#### Scenario: busy owner holds, idle owner releases

- **WHEN** a probe stays undeliverable past the defer limit and the
  owner reports mid-turn status
- **THEN** the task re-parks under `quota_source=busy-hold`, the
  orchestrator gets one `[QUOTA_PROBE]` notice naming task, instance
  and defer count, and `quota_probe_escalated`/`quota_probe_held_busy`
  events journal durably
- **AND** when the owner is absent, idle or unverifiable, or the
  episode's hold budget is exhausted, the park releases with
  `quota_probe_gave_up` exactly as before

### Requirement: a hung agent is never resumed without a checkpoint

When a parked step's background agent hangs (no structured report,
quota marker in its tail, no progress past its deadline), the
instance/daemon SHALL park the step and stop the hung agent -
`bridge agent-kill --agent <id>` (daemon cancel straight into the
instance runtime, bypassing the mailbox). A hung agent is NEVER
"resumed" hoping it will produce a report: resume requires a
saved checkpoint, and when resume is impossible or rejected a
fresh agent spawns from the checkpoint - it does not re-do
verified work.

#### Scenario: hung limit-blocked executor

- **WHEN** a background executor's tail shows a quota marker but no
  structured report arrives
- **THEN** the step parks (default window when the marker names no
  reset), the agent is killed via `agent-kill`, and resume happens
  only against a recorded checkpoint

### Requirement: model pools are tiered and the probe hits the right pool

Quota is a property of the model/pool, not of the agent. The
instance SHALL park against the pool the step actually used
(recorded as `quota_pool` in the park row) and the control probe
SHALL preflight that same pool. A step SHALL NOT silently downgrade
to another tier on park: a tier change is a caller decision made at
resume time (e.g. free tier parked, paid tier available). Pool
definitions (which models form a tier, probe cost ceiling) live in
project configuration, not in the canon.

#### Scenario: wrong-tier probe is invalid

- **WHEN** the recorded `quota_pool` differs from the pool the
  probe would exercise
- **THEN** the probe is invalid for that park - the daemon probes
  the recorded pool or defers

### Requirement: HALT is senior to a quota reset

A halted instance's expired quota park SHALL stay parked - the quota
pass sweeps it only after `bridge resume` lifts the halt.

#### Scenario: halted instance past reset

- **WHEN** `quota_reset_at` passed but the instance is halted
- **THEN** the park remains and no probe fires until resume

### Requirement: transport defaults are named and bounded once

Canonical defaults used by this spec (projects MAY override via
env, the names below are the contract):

- default park window when a marker carries no reset: 900 s
- probe pacing budget: dedicated, independent of wake cooldown
- defer window (probe transport failure re-park):
  `QUOTA_PROBE_DEFER_SECONDS` (default 900 s)
- per-episode defer limit: `QUOTA_PROBE_DEFER_LIMIT` (default 5),
  counted from the task's `quota_park` event
- busy hold: `QUOTA_BUSY_HOLD_SECONDS` (default
  3600 s), hold limit 3 per episode
- one `[QUOTA_PROBE]` escalation per episode (first give-up only;
  repeat give-ups re-hold silently)
