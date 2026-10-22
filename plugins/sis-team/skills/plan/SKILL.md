---
name: plan
description: Settle the design of one PLAN.md phase of the ship-it-safely lab before any code is written. Spawns the solution-architect, saves its ADR to docs/adr/, and stops for the user's approval. Use as /sis-team:plan <phase>.
argument-hint: <phase number>
---

# /sis-team:plan

Phase: `$ARGUMENTS` (ask for it if empty).

1. Read `PLAN.md` §8 for the phase and `docs/adr/*.md`. If the phase depends on an input still marked `TODO`
   in `PLAN.md` §3, ask the user for it now.
2. Spawn `sis-team:solution-architect` with: the phase number, its requirement IDs, the list of existing ADRs,
   and the answers from step 1.
3. Save the returned ADR as `docs/adr/NNNN-phase-<n>-<slug>.md` (next free number, status `proposed`). Keep
   the build briefs in the same file under `## Build briefs`.
4. Show the user a short summary: the decisions, open questions, and what they will run by hand at the
   checkpoint. Ask them to approve (status becomes `accepted`) or change it.
5. Stop. Do not start building in this skill.
