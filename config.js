/* AP Workbench settings. Fill in the three IDs; the rest has working defaults. */
window.AP_CONFIG = {
  tenantId:        "",   // Entra ID > Overview > Tenant ID
  clientId:        "",   // the app registration's Application (client) ID
  graphqlEndpoint: "",   // Fabric > your API for GraphQL item > "Copy endpoint"

  scopes: ["https://analysis.windows.net/powerbi/api/GraphQLApi.Execute.All"],
  pageSize: 5000,        // rows per GraphQL page
  pollSeconds: 60,       // pick up colleagues' changes this often

  // ap_aging_workspace holds one load of open lines, so no filter is needed.
  // (For a table with an is_open column use: "{ is_open: { eq: true } }")
  openFilter: "",
  loadIdField: "load_id",   // if several loads are ever in the table, only the newest is shown

  // Columns of sageintacct.ap_aging_workspace used by the app (left: app field, right: table column).
  // k is blank: the app builds the line key from vendor | document | line | project, the same key
  // the saved decisions use. Set it to a column name if the table gets its own key column.
  lineFields: {
    k: "", vid: "vendor_id", vn: "vendor_name", ds: "description", loc: "location_name",
    acct: "expense_account", pid: "project_id", cc: "cost_code", ct: "cost_type", ln: "line_no",
    doc: "document_number", idate: "invoice_date", amt: "amount", paid: "amount_paid",
    tot: "total", wc: "when_created", ed: "entry_date", seen: "loaded_at", asOf: "as_of_date"
  },

  // GraphQL names. Leave blank: the app finds them automatically and lists what it sees if it can't.
  names: { lines: "", decisions: "", rules: "", runs: "", runLines: "",
           setDecisions: "", saveRules: "", saveRun: "", deleteRun: "" }
};
