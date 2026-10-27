# infra/terraform

All Terraform for the lab. Three kinds of directories, each with its own `README.md` (ADR 0001, D16):

| Path | Kind | State | Who applies | Phase |
|---|---|---|---|---|
| [`bootstrap/`](bootstrap/) | Root, once per AWS account | `bootstrap/terraform.tfstate` in the account's state bucket | You, locally, with SSO admin | 1 |
| [`modules/app-ecs/`](modules/app-ecs/) | Module (no provider, no backend) | n/a | Called by `envs/<env>` | 3 |
| [`envs/dev/`](envs/dev/) | Root, one per environment | `envs/dev/terraform.tfstate` | CI apply role, after approval | 3 |

Order: `bootstrap` first (it creates the state bucket and the CI roles), then `envs/<env>`.

## Conventions

- **Roots** (`bootstrap/`, `envs/<env>/`) own `versions.tf`, `providers.tf` (with `default_tags`), a partial
  `backend.tf`, and their inputs (`*.tfvars.example` or a committed `terraform.tfvars` without account IDs).
  `envs/<env>` stays thin: one `module` call plus variables and outputs.
- **Modules** declare `required_providers` in `versions.tf` but never a `provider` or `backend` block.
- **Every root and module has a `README.md`**: hand-written purpose and usage, plus the inputs, outputs and
  resources tables that `terraform-docs` writes between the `BEGIN_TF_DOCS` / `END_TF_DOCS` markers.
  `make tf-check` fails when a directory with `.tf` files has no README or no markers.
- File layout, naming, IAM and testing rules: [`CODING_STANDARDS.md`](../../docs/reference/CODING_STANDARDS.md#terraform-infraterraform).

## Commands

| Command | Does |
|---|---|
| `make tf-check` | Offline policy rules (`tf/policy.sh`), README check, `fmt`, `init -backend=false`, `validate`, `terraform test` (own temporary data dir, so a real `init` in a checkout does not disturb it) |
| `make docs` | Regenerate the `terraform-docs` tables in every README |

`plan`, `apply` and `destroy` are never `make` targets: you run them at the checkpoint, or CI runs them with
the OIDC roles. `envs/dev` is planned on every pull request and applied on `main` after approval by
`.github/workflows/terraform-iac.yml`, and destroyed only by the approval-gated
`.github/workflows/terraform-destroy.yml` (never from `make`); its CI tools are installed by `scripts/ci/install-tools.sh` with
pinned SHA-256 checksums.
