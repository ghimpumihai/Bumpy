# One user-assigned identity per service (plan §5 "Managed identities", D36). User-assigned rather than
# system-assigned so roles exist before the app or job that uses them is created.
#   ingest  – ingest function
#   worker  – stream processor + finalize and aggregate jobs (database user `writer`)
#   migrate – migrate job (database Entra admin `migrator`)
#   readapi – read API (database user `reader`)

resource "azurerm_user_assigned_identity" "this" {
  for_each            = toset(["ingest", "worker", "migrate", "readapi"])
  name                = "id-${var.project}-${each.key}"
  resource_group_name = local.rg
  location            = local.location
  tags                = local.tags
}
