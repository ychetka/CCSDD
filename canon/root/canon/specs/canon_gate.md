# Canon Gate: canon publication loop

Specification of the canon publication loop: CANON_WS (draft work
area) -> CANON_PUB (publication gate) -> CANON (immutable release)
-> OOB (rollout) -> WS (workers). Part of the canon; terms —
`glossary.md`; decisions and envelopes — `harness.md`; fleet —
`fleet.md`.

## 1. Writers and loops

- Canon is single-writer: only the owner instance drafts it (the
  `canon_owner` mark in FLEET, assigned by the human — `fleet.md`
  §4).
- Canon drafts live in the owner's work area (`canon_ws/`), NOT in
  `canon/`. Direct editing of `canon/` by an LLM session is
  forbidden: `root/` changes only as part of a published release.
- The `canon_owner` mark in `fleet_registry.json` is assigned ONLY
  by the human: changing it requires a signed human decision
  envelope (`harness.md`, "Human decision envelope"). Editing the
  mark or MANIFEST.json by hand from a session is a drift incident
  (failure_class=conflict, auditable event).

## 2. Publication gate (CANON_PUB)

- Publishing a candidate runs only through
  `canon/bin/canon_pub.sh`: drafts + validation (hygiene, candidate
  manifest sha comparison, agent read-line limit) + verification of
  the human approval envelope.
- The approval envelope — a signed record (see `harness.md` §3):
  `{verdict, artifact_sha, sig, signed_by, ts}`; `artifact_sha` must
  equal the candidate tree hash (PR head). The signature payload
  additionally binds the target `--version` string, so an envelope
  cannot be replayed under a different release number, and `ts`
  must sit inside a 24h freshness window — a stale approval is not
  a current decision. Without a valid envelope publication is
  rejected fail-closed — orchestrator self-publication of canon is
  impossible.
- A canon release = a `canon-v<canon_version>` tag (a separate
  semver space from product `v*`), a MANIFEST.json with sha256 of
  all files, a changelog and a record in the canon release history.
  The commit/tag is performed by the git agent after the script
  passes.
- A deployed canon's `RULES.md` points to this spec: the normative
  text lives here and deploys together with the canon.

## 3. Manifest

- `canon/MANIFEST.json` — the single authoritative list of canon
  files + `canon_version`. It also covers the orchestrator layer
  (`canon/orchestrator/`): changing PLAYBOOK, the protocol or an
  orchestrator script without a version bump and a manifest entry
  is a drift incident, not an "untracked" file.
- MANIFEST is recomputed only by `canon_pub.sh` as part of a
  release; hand-editing the sha map is manifest forgery.
- Any commit/merge to main touching manifest-covered paths must
  bump `canon_version` and end with a `canon-v<canon_version>` tag;
  the latest untagged commit that changed covered paths is a drift
  incident.

## 4. Rollout (OOB)

- A worker receives canon only from a released build: onboarding
  deploy verifies every file against the manifest sha256 AND checks
  that `canon_version` has a `canon-v<version>` tag in the canon repo
  (proof the gate was passed). An untagged version — onboarding
  refusal with a drift event, except an explicit
  `--allow-untagged-canon` (recorded in the instance journal).
- The rollout source is the release tag/manifest, not the owner's
  `canon_ws/` working tree: a draft never reaches workers.
