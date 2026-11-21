# Infrastructure (Terraform)

- Run Terraform only through `infra/tf.ps1` (it loads the gitignored `infra/.env`). Its commands are `bootstrap|init|plan|apply|output|destroy|fix-ingest-storage`; `init`, `plan` and `output` are safe. `bootstrap`, `apply`, `destroy` and `fix-ingest-storage` (deletes the provider-written `AzureWebJobsStorage` setting, `infra/README.md`) change Azure: never without the user's OK. The same goes for the `terraform-apply` workflow.
- azurerm is pinned `~> 4.40`; v3 examples use removed attributes, so check current docs (context7) before writing resources.
- Role assignments granted to a module's own identities stay in that module (e.g. Event Grid → queue in storage); the other cross-module roles go in `main/rbac.tf`.
- Role assignments take time to propagate: anything that uses a new one right away waits on a `time_sleep` (60 s), like the existing ones.
- GitHub OIDC subjects use the immutable format `repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:prod` / `:pull_request` (`bootstrap/main.tf`, D36). Don't change them to `repo:owner/name`.
- PostgreSQL public network access and password login are both off. Never turn either on to work around a login error; fix the Entra role or outbound access (D35, `psql_nat_gateway_enabled` in `.env.example`).
- Terraform ignores container images (`ignore_changes` on the image in `modules/compute/main.tf`); CI owns them. Never set an image here or remove that `ignore_changes`.
- Never change `TF_VAR_project` or rename resources: the storage account is named `st${var.project}…`, so a change replaces the data lake and its trips, and the deploy workflows hard-code `roadride`.
