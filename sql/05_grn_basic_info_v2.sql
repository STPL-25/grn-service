-- ============================================================
-- grn_basic_info (revised schema)
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Updated column set for the GRN header table, aligned with the
-- workflow/org-hierarchy convention used by po_request_info / pr_basic_info
-- (com_sno/div_sno/brn_sno/dept_sno, workflow_types_id, current_approver_id,
-- is_active, status, created_by/date, modified_by/date).
--
-- NOTE: this supersedes dbo.nt_grn_basic_info created in
-- grn-service/sql/01_grn.sql (grn_no there is VARCHAR(30) UNIQUE with no
-- org/workflow columns). Reconcile the two before running against the
-- live DB — either migrate nt_grn_basic_info to this shape, or run this
-- as a fresh table and update grn.repository.js accordingly.
-- ============================================================

IF OBJECT_ID('dbo.grn_basic_info', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.grn_basic_info (
        grn_basic_sno        INT           IDENTITY(1,1) PRIMARY KEY,
        grn_no                INT           NULL,
        com_sno               INT           NULL,
        div_sno               INT           NULL,
        brn_sno               INT           NULL,
        dept_sno              INT           NULL,
        gate_entry_sno        INT           NULL,
        po_basic_sno          INT           NULL,
        vendor_sno            INT           NULL,
        received_date         DATE          NULL,
        doc_ref_no            VARCHAR(100)  NULL,
        vehicle_no            VARCHAR(50)   NULL,
        challan_no            VARCHAR(50)   NULL,
        remarks               VARCHAR(100)  NULL,
        is_active             CHAR(1)       NOT NULL DEFAULT 'Y',
        workflow_types_id     INT           NULL,
        current_approver_id   VARCHAR(20)   NULL,
        status                CHAR(1)       NOT NULL DEFAULT 'P',
        created_by            VARCHAR(20)   NULL,
        created_date          DATE          NOT NULL DEFAULT GETDATE(),
        modified_by           VARCHAR(20)   NULL,
        modified_date         DATE          NULL
    );
END
GO
