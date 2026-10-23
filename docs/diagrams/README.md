# Diagrams

Architecture diagrams drawn with `/sis-team:diagram <topic>` from the Terraform, workflows and ADRs. Each has
an editable `.drawio` source and a `.drawio.png` export with the XML embedded, so either file opens in draw.io.
Grey dotted parts are planned and not in code yet.

| Diagram | Shows | Based on | Date |
|---|---|---|---|
| [bootstrap](bootstrap.drawio.png) | Phase 1: state bucket, OIDC provider, plan/apply/deploy roles and their trust, guardrail and boundary policies, budget; the Phase 3 resources the roles are scoped to | `ebdfe3f` | 2026-10-23 |

Regenerate or extend one with `/sis-team:diagram <topic>`; it validates the file, exports it and checks the PNG.
