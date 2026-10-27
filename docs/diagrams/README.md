# Diagrams

Architecture diagrams drawn with `/sis-team:diagram <topic>` from the Terraform, workflows and ADRs. Each has
an editable `.drawio` source and a `.drawio.png` export with the XML embedded, so either file opens in draw.io.
Grey dotted parts are planned and not in code yet.

| Diagram | Shows | Based on | Date |
|---|---|---|---|
| [bootstrap](bootstrap.drawio.png) | State bucket, OIDC provider, plan/apply/deploy roles and their trust (including `job_workflow_ref` and the region pin), guardrail and boundary policies, budget, and the envs/dev resources the roles are scoped to | `e43b2f9` | 2026-10-27 |
| [bootstrap: security alert](bootstrap-security-alert.drawio.png) | Page 2 of `bootstrap.drawio`: STS, the CloudTrail trail and its bucket, the EventBridge rule, the SNS topic and email, guardrail G6 | `e43b2f9` | 2026-10-27 |

Regenerate or extend one with `/sis-team:diagram <topic>`; it validates the file, exports it and checks the PNG.
