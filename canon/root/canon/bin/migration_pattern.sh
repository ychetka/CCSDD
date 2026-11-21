#!/usr/bin/env bash
# migration_pattern.sh - single source for the migration-path pattern.
# Sourced by migration_gate.sh and ship_commit.sh so the stamp hash
# and the verification pass always classify the same file set. Do not
# copy the regex into another script - source this file instead.
# Flyway naming: V<n>__ / U<n>__ (versioned/undo) and R__ (repeatable
# migrations) anywhere in the tree; directory conventions cover
# Alembic, Rails db/migrate, Liquibase and generic migrations/.
MIG_PAT='(^|/)(migrations?|alembic/versions|db/migrate|flyway|liquibase)/|(^|/)([VU][0-9]+(_[0-9]+)*|R)__.*\.sql$'
