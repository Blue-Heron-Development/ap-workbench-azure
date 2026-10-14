/* Who can use the workbench. Users can read the ap tables and run the procedures,
   but cannot INSERT/UPDATE/DELETE directly – so every change goes through the
   procedures and lands in ap.change_log. */
CREATE ROLE ap_workbench_user;
GRANT SELECT  ON SCHEMA::ap TO ap_workbench_user;
GRANT EXECUTE ON SCHEMA::ap TO ap_workbench_user;
GO
/* Add each person (repeat per user, or use an Entra security group): */
-- CREATE USER [traci@blueheron.com] FROM EXTERNAL PROVIDER;
-- ALTER ROLE ap_workbench_user ADD MEMBER [traci@blueheron.com];
