# AP Workbench on Azure Static Web Apps + Fabric

The workbench Traci uses, reading Sage data from the Lakehouse table
`sageintacct.ap_aging_workspace` and saving decisions, notes, pay runs and rules to a
Fabric SQL database, through one Fabric **API for GraphQL**. Users sign in with their
Microsoft account; every change is logged with who made it.

```
sageintacct.ap_aging_workspace (Lakehouse, read) ─┐
                                                  ├─ API for GraphQL ─ this web app (Entra sign-in)
ap.* tables + procedures (Fabric SQL database)   ─┘
```

## Files
| File | Purpose |
|---|---|
| `index.html` | The app (single page, no build step) |
| `config.js` | Tenant ID, client ID, GraphQL endpoint, column names |
| `staticwebapp.config.json` | Azure Static Web Apps settings and security headers |
| `sql/01_schema.sql` | Tables, current-rules view, save procedures with change logging |
| `sql/02_migrate.sql` | The 3,122 decisions and 19 rules from the current workbench |
| `sql/03_permissions.sql` | Role for workbench users (read + run procedures only) |

## Setup (about an hour)

### 1. Fabric SQL database
1. In the workspace: **New item → SQL database**, e.g. `db_ap_workbench`.
2. Run `sql/01_schema.sql`, then `sql/02_migrate.sql`, then `sql/03_permissions.sql`.
   The scripts use `GO` between batches: run them from VS Code (mssql extension) or SSMS
   connected to the database, or in the Fabric query editor run each block between `GO`s separately.
3. Add each user to `ap_workbench_user` (or an Entra group). Workspace Admins/Members already have access.

### 2. The Lakehouse table
The app reads these columns from `sageintacct.ap_aging_workspace`:
`vendor_id, vendor_name, description, location_name, expense_account, project_id, cost_code, cost_type,
line_no, document_number, invoice_date, amount, amount_paid, total, when_created, entry_date,
as_of_date, load_id, loaded_at`. It builds each line's key (vendor | document | line | project) itself,
the same key the saved decisions use. If a column is renamed, change it under `lineFields` in `config.js`.

### 3. API for GraphQL
1. **New item → API for GraphQL**, e.g. `gql_ap_workbench`. Connectivity: **Single sign-on**
   (so the procedures log each person's own identity).
2. **Get data** → the Lakehouse → select `sageintacct.ap_aging_workspace`.
3. **Get data** → the SQL database → select `ap.line_decision`, `ap.v_current_rules`, `ap.pay_run`,
   `ap.pay_run_line`, and the procedures `ap.usp_set_decisions`, `ap.usp_save_rules`,
   `ap.usp_save_pay_run`, `ap.usp_delete_pay_run`.
4. **Manage permissions** → give users **Run Queries and Mutations**.
5. **Copy endpoint** – goes into `config.js`.

### 4. Entra app registration
1. Entra ID → **App registrations → New registration**, name `AP Workbench`, single tenant.
2. **Authentication → Add a platform → Single-page application**, redirect URIs:
   your Static Web App URL (e.g. `https://<name>.azurestaticapps.net/`) and `http://localhost:4280/` for testing.
3. **API permissions → Add → Power BI Service → Delegated → `GraphQLApi.Execute.All`**, then **Grant admin consent**.
4. Copy the **Application (client) ID** and **Directory (tenant) ID** into `config.js`.

### 5. Deploy to Azure Static Web Apps
1. Azure portal → **Create Static Web App** (Free plan is enough), deployment source **Other**.
2. Copy its **deployment token**, then from this folder:
   ```
   npm install -g @azure/static-web-apps-cli
   swa deploy . --env production --deployment-token <token>
   ```
3. Open the site, sign in. If a table or procedure is missing from the GraphQL API, the app lists
   exactly what it found so you can add the missing item.

To test locally first: `swa start .` and open http://localhost:4280.

## Day to day
- The Fabric pipeline refreshes `ap_aging_workspace` each morning; **Refresh** in the app reloads it.
- Edits save within a second; colleagues see each other's changes within a minute (or on Refresh).
- Audit: `SELECT * FROM ap.change_log ORDER BY changed_at DESC` – who changed which line, from what, to what.
- Rule history: every save is a new row in `ap.rule_set`; roll back by re-saving an old version.

## Notes
- Users cannot edit the ap tables directly (`03_permissions.sql`), so nothing bypasses the change log.
- The page itself is public, but shows nothing without a Blue Heron sign-in and access to the GraphQL API.
  To hide even the sign-in page, enable Static Web Apps authentication restricted to your tenant.
