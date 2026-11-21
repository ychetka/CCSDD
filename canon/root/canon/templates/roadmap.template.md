# Roadmap item template

Copy the `## Item` block per roadmap item. All fields are mandatory
unless marked optional. See `canon/specs/harness.md` §4 for the item
lifecycle and field semantics.

```markdown
## Item: <slug>

- id: <stable slug, referenced by depends_on and .changes fragments>
- type: contract | test | infra | implementation | exploration |
  docs | refactor
- status: draft | judged | signed_off | in_progress | done |
  blocked | escalated
- depends_on: [<item slugs>]            # empty list if none
- contracts: [<contract file paths>]    # frozen by hash at sign-off
- stack_area: fe | be | infra | shared  # FE-BE boundary decision
- risk_flags: [<auth | persistence | boundary | migration | ...>]
  # items touching contract/schema files, auth or persistence
  # boundaries get mandatory review escalation (harness.md)
- frozen_hash: <sha256 of item text>    # filled at criteria freeze
- pr: <PR number once assembled>        # optional
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
