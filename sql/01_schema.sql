/* =====================================================================
   AP Workbench – Fabric SQL database objects
   Run once in the Fabric SQL database (e.g. db_ap_workbench).
   The Sage data stays in the Lakehouse table sageintacct.ap_aging_workspace;
   this database holds only what people decide and change.
   ===================================================================== */
CREATE SCHEMA ap;
GO

/* One row per AP line that someone has moved to a tab or noted. Keyed by the same
   line_key the Lakehouse table uses (vendor | document | line | project). */
CREATE TABLE ap.line_decision (
    line_key     NVARCHAR(400)  NOT NULL CONSTRAINT pk_line_decision PRIMARY KEY,
    bucket       NVARCHAR(20)   NULL,      -- AGING, ISSUES, DF, SGA, DEV, CANYONS, SL, ATELIER, RET, REMOVED; NULL = use rules
    note         NVARCHAR(2000) NULL,
    updated_by   NVARCHAR(256)  NOT NULL,
    updated_at   DATETIME2(0)   NOT NULL CONSTRAINT df_line_decision_at DEFAULT SYSUTCDATETIME()
);
GO

/* Append-only audit of every change made through the workbench. */
CREATE TABLE ap.change_log (
    log_id       BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_change_log PRIMARY KEY,
    entity       NVARCHAR(20)   NOT NULL,  -- line, rules, pay_run
    entity_key   NVARCHAR(400)  NOT NULL,
    field        NVARCHAR(40)   NOT NULL,
    old_value    NVARCHAR(MAX)  NULL,
    new_value    NVARCHAR(MAX)  NULL,
    changed_by   NVARCHAR(256)  NOT NULL,
    changed_at   DATETIME2(0)   NOT NULL CONSTRAINT df_change_log_at DEFAULT SYSUTCDATETIME()
);
CREATE INDEX ix_change_log_entity ON ap.change_log (entity, entity_key, changed_at);
GO

/* Sorting rules, versioned: every save adds a row; the newest is current. */
CREATE TABLE ap.rule_set (
    rule_set_id  INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_rule_set PRIMARY KEY,
    rules_json   NVARCHAR(MAX)  NOT NULL,
    labels_json  NVARCHAR(MAX)  NOT NULL,
    saved_by     NVARCHAR(256)  NOT NULL,
    saved_at     DATETIME2(0)   NOT NULL CONSTRAINT df_rule_set_at DEFAULT SYSUTCDATETIME()
);
GO
CREATE VIEW ap.v_current_rules AS
SELECT TOP (1) rule_set_id, rules_json, labels_json, saved_by, saved_at
FROM ap.rule_set ORDER BY rule_set_id DESC;
GO

/* Pay runs and the lines in them (amounts snapshotted when added). */
CREATE TABLE ap.pay_run (
    run_id       NVARCHAR(40)   NOT NULL CONSTRAINT pk_pay_run PRIMARY KEY,
    name         NVARCHAR(200)  NOT NULL,
    pay_date     DATE           NULL,
    status       NVARCHAR(20)   NOT NULL,  -- draft, released
    created_by   NVARCHAR(256)  NOT NULL,
    created_at   DATETIME2(0)   NOT NULL,
    released_by  NVARCHAR(256)  NULL,
    released_at  DATETIME2(0)   NULL,
    updated_by   NVARCHAR(256)  NOT NULL,
    updated_at   DATETIME2(0)   NOT NULL
);
CREATE TABLE ap.pay_run_line (
    run_id          NVARCHAR(40)  NOT NULL,
    line_key        NVARCHAR(400) NOT NULL,
    vendor_id       NVARCHAR(100) NULL,
    vendor_name     NVARCHAR(300) NULL,
    project_id      NVARCHAR(100) NULL,
    document_number NVARCHAR(200) NULL,
    line_no         NVARCHAR(20)  NULL,
    invoice_date    DATE          NULL,
    amount          DECIMAL(18,2) NULL,
    from_bucket     NVARCHAR(20)  NULL,
    CONSTRAINT pk_pay_run_line PRIMARY KEY (run_id, line_key)
);
GO

/* ---------------------------------------------------------------------
   Write procedures (exposed by Fabric API for GraphQL as mutations).
   @app_user is the name the app shows; SUSER_SNAME() is the signed-in
   identity Fabric passes through with single sign-on – that is what we log.
   --------------------------------------------------------------------- */

/* Save tab moves and notes for many lines at once.
   @items = JSON array: [{"line_key":"...","set_bucket":true,"bucket":"DF","set_note":false,"note":null}, ...]
   bucket null with set_bucket true = back to the rules. */
CREATE PROCEDURE ap.usp_set_decisions
    @items    NVARCHAR(MAX),
    @app_user NVARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @who NVARCHAR(256) = COALESCE(NULLIF(SUSER_SNAME(), ''), @app_user, 'unknown');

    /* table variable, not a #temp table: GraphQL reads the result shape with sp_describe_first_result_set,
       which cannot see into temp tables */
    DECLARE @in TABLE (line_key NVARCHAR(400) PRIMARY KEY, set_bucket BIT, bucket NVARCHAR(20), set_note BIT, note NVARCHAR(2000));
    INSERT @in (line_key, set_bucket, bucket, set_note, note)
    SELECT line_key, ISNULL(set_bucket, 0), bucket, ISNULL(set_note, 0), note
    FROM OPENJSON(@items) WITH (
        line_key   NVARCHAR(400)  '$.line_key',
        set_bucket BIT            '$.set_bucket',
        bucket     NVARCHAR(20)   '$.bucket',
        set_note   BIT            '$.set_note',
        note       NVARCHAR(2000) '$.note');

    BEGIN TRAN;
        INSERT ap.change_log (entity, entity_key, field, old_value, new_value, changed_by)
        SELECT 'line', i.line_key, 'bucket', d.bucket, NULLIF(i.bucket, ''), @who
        FROM @in i LEFT JOIN ap.line_decision d ON d.line_key = i.line_key
        WHERE i.set_bucket = 1 AND ISNULL(d.bucket, '') <> ISNULL(i.bucket, '');

        INSERT ap.change_log (entity, entity_key, field, old_value, new_value, changed_by)
        SELECT 'line', i.line_key, 'note', d.note, NULLIF(i.note, ''), @who
        FROM @in i LEFT JOIN ap.line_decision d ON d.line_key = i.line_key
        WHERE i.set_note = 1 AND ISNULL(d.note, '') <> ISNULL(i.note, '');

        MERGE ap.line_decision AS t
        USING @in AS s ON t.line_key = s.line_key
        WHEN MATCHED THEN UPDATE SET
            bucket     = CASE WHEN s.set_bucket = 1 THEN NULLIF(s.bucket, '') ELSE t.bucket END,
            note       = CASE WHEN s.set_note   = 1 THEN NULLIF(s.note, '')   ELSE t.note   END,
            updated_by = @who, updated_at = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT (line_key, bucket, note, updated_by)
            VALUES (s.line_key,
                    CASE WHEN s.set_bucket = 1 THEN NULLIF(s.bucket, '') END,
                    CASE WHEN s.set_note   = 1 THEN NULLIF(s.note, '')   END, @who);

        DELETE FROM ap.line_decision WHERE bucket IS NULL AND note IS NULL;   -- nothing left to remember
    COMMIT;

    SELECT COUNT(*) AS affected FROM @in;
END;
GO

/* Save a new version of the sorting rules. */
CREATE PROCEDURE ap.usp_save_rules
    @rules_json  NVARCHAR(MAX),
    @labels_json NVARCHAR(MAX),
    @app_user    NVARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@rules_json) = 0 OR ISJSON(@labels_json) = 0 THROW 50001, 'Rules must be valid JSON.', 1;
    DECLARE @who NVARCHAR(256) = COALESCE(NULLIF(SUSER_SNAME(), ''), @app_user, 'unknown');
    DECLARE @prev INT = (SELECT MAX(rule_set_id) FROM ap.rule_set);
    INSERT ap.rule_set (rules_json, labels_json, saved_by) VALUES (@rules_json, @labels_json, @who);
    DECLARE @id INT = SCOPE_IDENTITY();
    INSERT ap.change_log (entity, entity_key, field, old_value, new_value, changed_by)
    VALUES ('rules', CAST(@id AS NVARCHAR(20)), 'rule_set', CAST(@prev AS NVARCHAR(20)), CAST(@id AS NVARCHAR(20)), @who);
    SELECT @id AS rule_set_id;
END;
GO

/* Create or replace a pay run with its lines.
   @run_json = {"run_id":"...","name":"...","pay_date":"2026-10-14","status":"draft",
                "lines":[{"line_key":"...","vendor_id":"...","vendor_name":"...","project_id":"...",
                          "document_number":"...","line_no":"1","invoice_date":"2026-09-01","amount":123.45,"from_bucket":"DF"}]}
   @expected_updated_at: the updated_at the app last saw (NULL for a new run) – stops two people overwriting each other. */
CREATE PROCEDURE ap.usp_save_pay_run
    @run_json            NVARCHAR(MAX),
    @expected_updated_at DATETIME2(0) = NULL,
    @app_user            NVARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @who NVARCHAR(256) = COALESCE(NULLIF(SUSER_SNAME(), ''), @app_user, 'unknown');
    DECLARE @run_id NVARCHAR(40) = JSON_VALUE(@run_json, '$.run_id');
    DECLARE @name NVARCHAR(200) = JSON_VALUE(@run_json, '$.name');
    DECLARE @pay_date DATE = TRY_CONVERT(DATE, JSON_VALUE(@run_json, '$.pay_date'));
    DECLARE @status NVARCHAR(20) = JSON_VALUE(@run_json, '$.status');
    IF @run_id IS NULL OR @name IS NULL OR @status NOT IN ('draft', 'released') THROW 50002, 'Pay run needs run_id, name and status draft/released.', 1;

    BEGIN TRAN;
        DECLARE @cur_status NVARCHAR(20), @cur_at DATETIME2(0);
        SELECT @cur_status = status, @cur_at = updated_at FROM ap.pay_run WITH (UPDLOCK) WHERE run_id = @run_id;
        IF @cur_at IS NOT NULL AND @expected_updated_at IS NOT NULL AND @cur_at <> @expected_updated_at
        BEGIN
            ROLLBACK; THROW 50003, 'Someone else changed this pay run. Reload and try again.', 1;
        END;

        IF @cur_at IS NULL
            INSERT ap.pay_run (run_id, name, pay_date, status, created_by, created_at, updated_by, updated_at,
                               released_by, released_at)
            VALUES (@run_id, @name, @pay_date, @status, @who, SYSUTCDATETIME(), @who, SYSUTCDATETIME(),
                    CASE WHEN @status = 'released' THEN @who END, CASE WHEN @status = 'released' THEN SYSUTCDATETIME() END);
        ELSE
            UPDATE ap.pay_run SET name = @name, pay_date = @pay_date, status = @status,
                released_by = CASE WHEN @status = 'released' AND @cur_status <> 'released' THEN @who
                                   WHEN @status = 'draft' THEN NULL ELSE released_by END,
                released_at = CASE WHEN @status = 'released' AND @cur_status <> 'released' THEN SYSUTCDATETIME()
                                   WHEN @status = 'draft' THEN NULL ELSE released_at END,
                updated_by = @who, updated_at = SYSUTCDATETIME()
            WHERE run_id = @run_id;

        DELETE ap.pay_run_line WHERE run_id = @run_id;
        INSERT ap.pay_run_line (run_id, line_key, vendor_id, vendor_name, project_id, document_number, line_no,
                                invoice_date, amount, from_bucket)
        SELECT @run_id, line_key, vendor_id, vendor_name, project_id, document_number, line_no,
               TRY_CONVERT(DATE, invoice_date), amount, from_bucket
        FROM OPENJSON(@run_json, '$.lines') WITH (
            line_key NVARCHAR(400), vendor_id NVARCHAR(100), vendor_name NVARCHAR(300), project_id NVARCHAR(100),
            document_number NVARCHAR(200), line_no NVARCHAR(20), invoice_date NVARCHAR(10),
            amount DECIMAL(18,2), from_bucket NVARCHAR(20));

        INSERT ap.change_log (entity, entity_key, field, old_value, new_value, changed_by)
        VALUES ('pay_run', @run_id, CASE WHEN @cur_at IS NULL THEN 'created' ELSE 'saved' END,
                @cur_status, @status + ' / ' + CAST((SELECT COUNT(*) FROM ap.pay_run_line WHERE run_id = @run_id) AS NVARCHAR(10)) + ' lines', @who);
    COMMIT;

    SELECT run_id, updated_at FROM ap.pay_run WHERE run_id = @run_id;
END;
GO

CREATE PROCEDURE ap.usp_delete_pay_run
    @run_id   NVARCHAR(40),
    @app_user NVARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @who NVARCHAR(256) = COALESCE(NULLIF(SUSER_SNAME(), ''), @app_user, 'unknown');
    IF EXISTS (SELECT 1 FROM ap.pay_run WHERE run_id = @run_id AND status = 'released')
        THROW 50004, 'Released pay runs cannot be deleted. Reopen it first.', 1;
    BEGIN TRAN;
        DELETE ap.pay_run_line WHERE run_id = @run_id;
        DELETE ap.pay_run WHERE run_id = @run_id;
        INSERT ap.change_log (entity, entity_key, field, old_value, new_value, changed_by)
        VALUES ('pay_run', @run_id, 'deleted', NULL, NULL, @who);
    COMMIT;
    SELECT @run_id AS run_id;
END;
GO
