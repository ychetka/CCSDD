# Roadmap item template

Copy the `## Item` block per roadmap item. All fields are mandatory
unless marked optional. See `canon/specs/harness.md` §4 for the item
lifecycle and field semantics.

```markdown
## Item: <slug>

- id: <stable slug, referenced by depends_on and .changes fragments>
- type: contract | test | infra | implementation | exploration |
  docs | refactor | epic        # epic = decomposed into task items
                                # (epic_issue_<N>-<slug> branch)
- status: draft | judged | signed_off | in_progress | done |
  blocked | escalated
- depends_on: [<item slugs>]            # empty list if none
- contracts: [<contract file paths>]    # frozen by hash at sign-off
- stack_area: fe | be | infra | shared  # FE-BE boundary decision
- risk_flags: [<auth | persistence | boundary | migration | ...>]
  # items touching contract/schema files, auth or persistence
  # boundaries get mandatory review escalation (harness.md)
- frozen_hash: <sha256>                 # filled at criteria freeze:
                                        # sha256 over the item block
                                        # text with the mutable fields
                                        # status/pr/issue/frozen_hash
                                        # REMOVED first, then the
                                        # remaining lines joined by
                                        # \n in file order (no
                                        # re-sorting, trailing spaces
                                        # stripped per line)
- pr: <PR number once assembled>        # optional
- issue: <tracker issue number>         # epic items: REQUIRED —
                                        # binds epic_issue_<N>-<slug>
                                        # to this item in epic_merge
- tasks: [<issue numbers>]              # epic items only: the task
                                        # issues composing the epic;
                                        # epic_merge gates that each
                                        # is shipped (.changes
                                        # fragment on the epic branch)
                                        # and CLOSED in the tracker
```

### Acceptance criteria (G/W/T)

One scenario = one test. Names are stable — `.changes` fragments and
coverage checks reference them.

```markdown
#### Scenario: <name>
- **GIVEN** <precondition / context>
- **WHEN** <triggering action>
- **THEN** <observable outcome>
- **AND** <additional invariant>        # optional
```

### Exploration items only

```markdown
- research_questions:
    - <question the research must answer>
- method_bounds: documentation_only | prototype_allowed |
  api_list:[...]                          # what the research may touch
```

### Optional fields

```markdown
- additional_acceptance_notes: <from partner pre-consultation p.4a>
- design_dissent: |
    <preserved minority position of the arch committee, verbatim>
```

The contract file MAY carry a `## Delegated decisions` block
(harness.md §3): explicit freedom axes with constraints, frozen by
the sign-off hash. Format, one axis per line:

```markdown
## Delegated decisions
- axis: <name> | constraint: <binding constraint>
```

Undetermined points outside the declared axes are contract gaps —
escalation, never improvisation. When at least one axis is
declared, the designer resolves them into an impl spec and
`design_spec_check.sh` gates the spec before the executor spawn
(harness.md §4b).
