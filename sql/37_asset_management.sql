-- ============================================================
-- 37_asset_management.sql  —  GRN › Asset Management (Non-Regular items issued to departments)
-- Database : Non_trade_Dev  (run from grn-service:  node sql/run_sql.mjs sql/37_asset_management.sql)
--
-- Flow (approved in docs/asset_management_flow.pdf):
--   * Asset register = Non-Regular sub-category items that were issued (nt_stock_request_items.issued_qty > 0),
--     shown department-wise / product-wise with the issue date. Derived live — no copy table.
--   * A Return / Service request can be raised by the Department or by a Store In-charge (anyone holding the
--     StoreIssuePage screen). Store-raised requests need DEPARTMENT approval first.
--   * RETURN : Purchase Dept approval chain -> Return Order -> goods out (gate pass OUT + DC) -> Debit Note -> Closed.
--   * SERVICE: approval chain (payment applicable Y/N is recorded) ->
--       OUTPASS : DC created at request -> gate OUT -> At Vendor -> gate IN (same DC) -> service receipt (GRN
--                 against DC) -> OK = Completed | NOT OK = QC Failed -> Debit Note -> Re-service.
--       INSTORE : Start service -> complete: OK = Completed | NOT OK = stays In Progress (rework counted).
--   * Quantities are reserved the moment a request is raised: in-use = issued - returned - in-service, so the
--     item leaves the ASSETS tab and shows in IN SERVICE / RETURNS until it comes back OK.
--   * Approvers come from nt_asset_approval_config (entity DEPT / RETURN / SERVICE, ordered stages) — seeded below
--     with the same approvers used elsewhere on Dev; replace rows to change them.
--   * Debit notes reuse dbo.debit_note_basic_info (grn/po made nullable + asset_request_sno added).
-- Re-runnable.
-- ============================================================

-- ── Tables ────────────────────────────────────────────────────────────────

IF OBJECT_ID('dbo.nt_asset_approval_config', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_asset_approval_config (
        cfg_sno       INT IDENTITY(1,1) PRIMARY KEY,
        entity        VARCHAR(10)  NOT NULL,        -- DEPT | RETURN | SERVICE
        stage_order   INT          NOT NULL,
        stage_name    VARCHAR(100) NOT NULL,
        approver_ecno VARCHAR(50)  NOT NULL,
        dept_sno      INT          NULL,            -- NULL = default for every department
        is_active     CHAR(1)      NOT NULL DEFAULT 'Y'
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.nt_asset_approval_config)
BEGIN
    INSERT INTO dbo.nt_asset_approval_config (entity, stage_order, stage_name, approver_ecno) VALUES
        ('DEPT',    1, 'Department Approval',  'KTM1148'),
        ('RETURN',  1, 'Purchase Department', 'KTM1148'),
        ('RETURN',  2, 'Head Approval',       'KTM1004'),
        ('SERVICE', 1, 'Service Approval',    'KTM1004');
END
GO

IF OBJECT_ID('dbo.nt_asset_requests', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_asset_requests (
        asset_req_sno        INT IDENTITY(1,1) PRIMARY KEY,
        request_no           VARCHAR(30)   NOT NULL UNIQUE,     -- ARR-YYYY-0001 (return) | ASV-YYYY-0001 (service)
        request_type         VARCHAR(10)   NOT NULL,            -- RETURN | SERVICE
        sr_item_sno          INT           NOT NULL,            -- the issued line (nt_stock_request_items)
        stock_request_sno    INT           NOT NULL,
        issue_ref            VARCHAR(30)   NULL,                -- SR-YYYY-nnnn
        item_sno             INT           NOT NULL,
        item_code            VARCHAR(50)   NULL,
        item_name            VARCHAR(255)  NULL,
        uom                  VARCHAR(20)   NULL,
        qty                  DECIMAL(18,2) NOT NULL,
        reason               VARCHAR(500)  NOT NULL,
        raised_by            VARCHAR(50)   NOT NULL,
        raised_by_name       VARCHAR(255)  NULL,
        raised_role          VARCHAR(10)   NOT NULL,            -- DEPT | STORE
        com_sno              INT NULL, div_sno INT NULL, brn_sno INT NULL, dept_sno INT NULL,
        status               VARCHAR(30)   NOT NULL,
        current_approver_ecno VARCHAR(50)  NULL,
        reject_reason        VARCHAR(500)  NULL,
        supplier_sno         INT           NULL,                -- kyc_basic_info (debit note / return target)
        payment_applicable   CHAR(1)       NULL,                -- SERVICE only
        est_amount           DECIMAL(18,2) NULL,
        service_mode         VARCHAR(10)   NULL,                -- OUTPASS | INSTORE
        service_vendor       VARCHAR(255)  NULL,                -- repair vendor / in-store technician
        expected_return_date DATE          NULL,
        cycle_no             INT           NOT NULL DEFAULT 1,  -- bumps on re-service
        rework_count         INT           NOT NULL DEFAULT 0,  -- in-store NOT OK loops
        return_order_no      VARCHAR(30)   NULL,
        return_order_date    DATETIME      NULL,
        dc_no                VARCHAR(30)   NULL,
        dc_date              DATETIME      NULL,
        gate_out_no          VARCHAR(30)   NULL,
        gate_out_at          DATETIME      NULL,
        gate_in_no           VARCHAR(30)   NULL,
        gate_in_at           DATETIME      NULL,
        service_receipt_no   VARCHAR(30)   NULL,                -- GRN against DC
        qc_result            VARCHAR(10)   NULL,                -- OK | NOT_OK
        debit_note_sno       INT           NULL,
        completed_at         DATETIME      NULL,
        created_at           DATETIME      NOT NULL DEFAULT GETDATE(),
        updated_at           DATETIME      NULL
    );
    CREATE INDEX IX_nt_asset_requests_item   ON dbo.nt_asset_requests (sr_item_sno, status);
    CREATE INDEX IX_nt_asset_requests_status ON dbo.nt_asset_requests (status, request_type);
END
GO

IF OBJECT_ID('dbo.nt_asset_request_approvals', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_asset_request_approvals (
        approval_sno  INT IDENTITY(1,1) PRIMARY KEY,
        asset_req_sno INT          NOT NULL,
        seq           INT          NOT NULL,                    -- global order across phases
        phase         VARCHAR(5)   NOT NULL,                    -- DEPT | MAIN
        stage_name    VARCHAR(100) NULL,
        approver_ecno VARCHAR(50)  NOT NULL,
        status        VARCHAR(10)  NOT NULL DEFAULT 'Waiting',  -- Waiting | Pending | Approved | Rejected | Skipped
        acted_by      VARCHAR(50)  NULL,
        acted_at      DATETIME     NULL,
        remarks       VARCHAR(500) NULL
    );
    CREATE INDEX IX_nt_asset_req_appr ON dbo.nt_asset_request_approvals (asset_req_sno, seq);
END
GO

IF OBJECT_ID('dbo.nt_asset_request_history', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_asset_request_history (
        hist_sno      INT IDENTITY(1,1) PRIMARY KEY,
        asset_req_sno INT          NOT NULL,
        event         VARCHAR(60)  NOT NULL,
        remarks       VARCHAR(500) NULL,
        by_ecno       VARCHAR(50)  NULL,
        at            DATETIME     NOT NULL DEFAULT GETDATE()
    );
    CREATE INDEX IX_nt_asset_req_hist ON dbo.nt_asset_request_history (asset_req_sno, hist_sno);
END
GO

-- ── Debit note reuse: asset debit notes have no GRN / PO ──────────────────

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.debit_note_basic_info') AND name = 'grn_basic_sno' AND is_nullable = 0)
    ALTER TABLE dbo.debit_note_basic_info ALTER COLUMN grn_basic_sno INT NULL;
GO
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.debit_note_basic_info') AND name = 'po_basic_sno' AND is_nullable = 0)
    ALTER TABLE dbo.debit_note_basic_info ALTER COLUMN po_basic_sno INT NULL;
GO
IF COL_LENGTH('dbo.debit_note_basic_info', 'asset_request_sno') IS NULL
    ALTER TABLE dbo.debit_note_basic_info ADD asset_request_sno INT NULL;
GO
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.debit_note_history_data') AND name = 'po_basic_sno' AND is_nullable = 0)
    ALTER TABLE dbo.debit_note_history_data ALTER COLUMN po_basic_sno INT NULL;
GO
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.debit_note_history_data') AND name = 'grn_basic_sno' AND is_nullable = 0)
    ALTER TABLE dbo.debit_note_history_data ALTER COLUMN grn_basic_sno INT NULL;
GO

-- The debit note list inner-joined the GRN; asset debit notes have none, so LEFT JOIN it and expose the asset ref.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAllDebitNotes
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @status = JSON_VALUE(@jsonInput, '$.status');

    SELECT
        b.debit_note_sno,
        b.debit_note_no,
        b.grn_basic_sno,
        CASE WHEN g.grn_basic_sno IS NULL THEN NULL
             ELSE 'GRN-' + CAST(YEAR(g.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(g.grn_no AS VARCHAR(6)), 6) END AS grn_no,
        b.po_basic_sno,
        p.po_df_no                                  AS po_no,
        b.vendor_sno,
        k.company_name                               AS vendor_name,
        c.com_name                                   AS com_name,
        b.vendor_invoice_no,
        CONVERT(VARCHAR(10), b.vendor_invoice_date, 120) AS vendor_invoice_date,
        CONVERT(VARCHAR(10), b.debit_note_date, 120)  AS debit_note_date,
        b.total_qty,
        b.total_amount,
        b.remarks,
        b.status,
        b.created_by                                  AS raised_by,
        CONVERT(VARCHAR(30), b.created_date, 120)      AS created_at,
        b.asset_request_sno,
        ar.request_no                                 AS asset_request_no,
        (
            SELECT
                di.debit_note_item_sno,
                di.grn_item_sno,
                di.po_item_sno,
                di.prod_sno,
                di.prod_name,
                di.specification,
                di.unit_name,
                di.reason_type,
                di.qty,
                di.unit_price,
                di.amount,
                di.remarks
            FROM dbo.debit_note_item_details di
            WHERE di.debit_note_sno = b.debit_note_sno
              AND di.is_active = 'Y'
            FOR JSON PATH
        )                                              AS items
    FROM dbo.debit_note_basic_info b
    LEFT JOIN dbo.grn_basic_info g  ON g.grn_basic_sno = b.grn_basic_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = b.vendor_sno
    LEFT JOIN dbo.company_master c  ON c.com_sno = b.com_sno
    LEFT JOIN dbo.nt_asset_requests ar ON ar.asset_req_sno = b.asset_request_sno
    WHERE b.is_active = 'Y'
      AND (@status IS NULL OR b.status = @status)
    ORDER BY b.debit_note_sno DESC;
END;
GO

-- ── Header view (one row per request, names resolved) ─────────────────────

CREATE OR ALTER VIEW dbo.vw_nt_asset_requests AS
SELECT
    q.asset_req_sno, q.request_no, q.request_type, q.sr_item_sno, q.stock_request_sno, q.issue_ref,
    q.item_sno, q.item_code, q.item_name, q.uom, q.qty, q.reason,
    q.raised_by, q.raised_by_name, q.raised_role,
    q.com_sno, q.div_sno, q.brn_sno, q.dept_sno, dp.dept_name,
    q.status, q.current_approver_ecno, ap.ename AS current_approver_name, q.reject_reason,
    q.supplier_sno, k.company_name AS supplier_name,
    q.payment_applicable, q.est_amount, q.service_mode, q.service_vendor,
    CONVERT(VARCHAR(10), q.expected_return_date, 120) AS expected_return_date,
    q.cycle_no, q.rework_count,
    q.return_order_no, CONVERT(VARCHAR(19), q.return_order_date, 120) AS return_order_date,
    q.dc_no, CONVERT(VARCHAR(19), q.dc_date, 120) AS dc_date,
    q.gate_out_no, CONVERT(VARCHAR(19), q.gate_out_at, 120) AS gate_out_at,
    q.gate_in_no, CONVERT(VARCHAR(19), q.gate_in_at, 120) AS gate_in_at,
    q.service_receipt_no, q.qc_result,
    q.debit_note_sno, dn.debit_note_no,
    CONVERT(VARCHAR(19), q.completed_at, 120) AS completed_at,
    CONVERT(VARCHAR(19), q.created_at, 120)   AS created_at,
    CONVERT(VARCHAR(19), q.updated_at, 120)   AS updated_at
FROM dbo.nt_asset_requests q
LEFT JOIN dbo.dept_master dp ON dp.dept_sno = q.dept_sno
LEFT JOIN dbo.vw_verified_employees ap ON ap.ecno = q.current_approver_ecno
LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = q.supplier_sno
LEFT JOIN dbo.debit_note_basic_info dn ON dn.debit_note_sno = q.debit_note_sno;
GO

-- ── sp_nt_GetAssetRegister ────────────────────────────────────────────────
-- @jsonInput: { hierarchy:[{com_sno,div_sno,brn_sno}], dept_sno?, search?, only_in_use? }
-- One row per issued line (department + product + issue). The UI groups by product.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAssetRegister
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL, @dept_sno INT = NULL, @search VARCHAR(100) = NULL, @only_in_use BIT = 0;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');
        SET @dept_sno      = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        SET @search        = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.search'))), '');
        SET @only_in_use   = CASE WHEN JSON_VALUE(@jsonInput, '$.only_in_use') IN ('1','true') THEN 1 ELSE 0 END;
    END

    SELECT * FROM (
        SELECT
            l.sr_item_sno, r.request_sno AS stock_request_sno, r.request_no AS issue_ref,
            l.item_sno, i.item_code, i.item_name, i.uom, i.prod_sno,
            cm.cat_name AS category, sc.subcat_name AS sub_category,
            r.dept_sno, dp.dept_name, r.com_sno, r.div_sno, r.brn_sno,
            c.com_name, dv.div_name, br.brn_name,
            r.requested_by, r.requested_name, r.received_by_ecno, r.received_by_name,
            l.issued_qty,
            CONVERT(VARCHAR(19), ISNULL(mv.first_issue, r.issued_at), 120) AS issue_date,
            a.returned_qty, a.service_qty,
            l.issued_qty - a.returned_qty - a.service_qty AS in_use_qty,
            ds.vendor_sno AS default_supplier_sno, k.company_name AS default_supplier_name
        FROM dbo.nt_stock_request_items l
        JOIN dbo.nt_stock_requests r      ON r.request_sno = l.request_sno
        JOIN dbo.nt_inventory_items i     ON i.item_sno = l.item_sno
        JOIN dbo.product_master p         ON p.prod_sno = i.prod_sno
        JOIN dbo.subcategory_master sc    ON sc.subcat_sno = p.subcat_sno AND sc.subcat_stock_type = 'Non-Regular'
        LEFT JOIN dbo.category_master cm  ON cm.cat_sno = p.cat_sno
        LEFT JOIN dbo.dept_master dp      ON dp.dept_sno = r.dept_sno
        LEFT JOIN dbo.company_master c    ON c.com_sno = r.com_sno
        LEFT JOIN dbo.division_master dv  ON dv.div_sno = r.div_sno
        LEFT JOIN dbo.branch_master br    ON br.brn_sno = r.brn_sno
        OUTER APPLY (
            SELECT ISNULL(SUM(CASE WHEN q.request_type = 'RETURN'  AND q.status NOT IN ('Rejected','Cancelled') THEN q.qty END), 0) AS returned_qty,
                   ISNULL(SUM(CASE WHEN q.request_type = 'SERVICE' AND q.status NOT IN ('Rejected','Cancelled','Completed') THEN q.qty END), 0) AS service_qty
            FROM dbo.nt_asset_requests q WHERE q.sr_item_sno = l.sr_item_sno
        ) a
        OUTER APPLY (
            SELECT MIN(m.created_at) AS first_issue
            FROM dbo.nt_stock_movements m
            WHERE m.reference_no = r.request_no AND m.item_sno = l.item_sno AND m.movement_type = 'OUT'
        ) mv
        OUTER APPLY (
            SELECT TOP 1 g.vendor_sno
            FROM dbo.grn_item_details gi
            JOIN dbo.grn_basic_info g ON g.grn_basic_sno = gi.grn_basic_sno AND g.is_active = 'Y'
            WHERE gi.prod_sno = i.prod_sno AND g.vendor_sno IS NOT NULL
            ORDER BY g.grn_basic_sno DESC
        ) ds
        LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = ds.vendor_sno
        WHERE l.issued_qty > 0
          AND (@dept_sno IS NULL OR r.dept_sno = @dept_sno)
          AND (@search IS NULL OR i.item_name LIKE '%' + @search + '%' OR i.item_code LIKE '%' + @search + '%'
                               OR r.request_no LIKE '%' + @search + '%' OR dp.dept_name LIKE '%' + @search + '%')
          AND (
                @HierarchyJson IS NULL
                OR EXISTS (
                    SELECT 1 FROM OPENJSON(@HierarchyJson)
                    WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                    WHERE h.com_sno = r.com_sno
                      AND (h.div_sno IS NULL OR h.div_sno = r.div_sno)
                      AND (h.brn_sno IS NULL OR h.brn_sno = r.brn_sno)
                )
          )
    ) x
    WHERE @only_in_use = 0 OR x.in_use_qty > 0
    ORDER BY x.dept_name, x.item_name, x.issue_date DESC;
END;
GO

-- ── sp_nt_GetAssetRequests ────────────────────────────────────────────────
-- @jsonInput: { hierarchy, request_type?, only_open?, approver_ecno?, status? }
-- approver_ecno => "waiting on me" list (not org-scoped: an approver acts wherever the request came from).
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAssetRequests
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL, @type VARCHAR(10) = NULL, @only_open BIT = 0,
            @approver VARCHAR(50) = NULL, @status VARCHAR(30) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');
        SET @type      = NULLIF(JSON_VALUE(@jsonInput, '$.request_type'), '');
        SET @only_open = CASE WHEN JSON_VALUE(@jsonInput, '$.only_open') IN ('1','true') THEN 1 ELSE 0 END;
        SET @approver  = NULLIF(JSON_VALUE(@jsonInput, '$.approver_ecno'), '');
        SET @status    = NULLIF(JSON_VALUE(@jsonInput, '$.status'), '');
    END

    SELECT v.*
    FROM dbo.vw_nt_asset_requests v
    WHERE (@type IS NULL OR v.request_type = @type)
      AND (@status IS NULL OR v.status = @status)
      AND (@only_open = 0 OR v.status NOT IN ('Completed','Closed','Rejected','Cancelled'))
      AND (@approver IS NULL OR v.current_approver_ecno = @approver)
      AND (
            @approver IS NOT NULL
            OR @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = v.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = v.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = v.brn_sno)
            )
      )
    ORDER BY v.asset_req_sno DESC;
END;
GO

-- ── sp_nt_GetAssetRequestDetail ───────────────────────────────────────────
-- Recordsets: 1 header, 2 approvals, 3 history
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAssetRequestDetail
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.asset_req_sno') AS INT);

    SELECT * FROM dbo.vw_nt_asset_requests WHERE asset_req_sno = @id;

    SELECT a.approval_sno, a.seq, a.phase, a.stage_name, a.approver_ecno, e.ename AS approver_name,
           a.status, a.acted_by, CONVERT(VARCHAR(19), a.acted_at, 120) AS acted_at, a.remarks
    FROM dbo.nt_asset_request_approvals a
    LEFT JOIN dbo.vw_verified_employees e ON e.ecno = a.approver_ecno
    WHERE a.asset_req_sno = @id ORDER BY a.seq;

    SELECT h.hist_sno, h.event, h.remarks, h.by_ecno, e.ename AS by_name, CONVERT(VARCHAR(19), h.at, 120) AS at
    FROM dbo.nt_asset_request_history h
    LEFT JOIN dbo.vw_verified_employees e ON e.ecno = h.by_ecno
    WHERE h.asset_req_sno = @id ORDER BY h.hist_sno;
END;
GO

-- ── sp_nt_GetAssetSuppliers ───────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAssetSuppliers
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT kyc_basic_info_sno AS supplier_sno, company_name, supp_code
    FROM dbo.kyc_basic_info
    WHERE is_active = 'Y' AND status = 'A' AND company_name IS NOT NULL
      AND ISNULL(vendor_category, '') <> 'SERVICE'   -- goods suppliers only; service vendors can't be returned to
    ORDER BY company_name;
END;
GO

-- ── sp_nt_AssetIsStoreIncharge (helper-style SP so the Node layer can show the right buttons) ──
CREATE OR ALTER PROCEDURE dbo.sp_nt_AssetIsStoreIncharge
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ecno VARCHAR(50) = JSON_VALUE(@jsonInput, '$.ecno');
    SELECT CASE WHEN EXISTS (
        SELECT 1
        FROM dbo.nt_user_permissions_json up
        CROSS APPLY OPENJSON(up.screens_json) WITH (screen_id INT '$.screen_id') s
        JOIN dbo.screens sc ON sc.screen_id = s.screen_id
        WHERE up.ecno = @ecno AND sc.comp IN ('StoreIssuePage', 'StockIssuePage')
    ) THEN 1 ELSE 0 END AS is_store_incharge;
END;
GO

-- ── sp_nt_CreateAssetRequest ──────────────────────────────────────────────
-- @jsonInput: { request_type, sr_item_sno, qty, reason, raised_by, raised_by_name, supplier_sno?,
--               payment_applicable?, est_amount?, service_mode?, service_vendor?, expected_return_date? }
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateAssetRequest
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @type      VARCHAR(10)   = UPPER(JSON_VALUE(@jsonInput, '$.request_type'));
    DECLARE @sr_item   INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.sr_item_sno') AS INT);
    DECLARE @qty       DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.qty') AS DECIMAL(18,2));
    DECLARE @reason    VARCHAR(500)  = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.reason'))), '');
    DECLARE @by        VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.raised_by');
    DECLARE @by_name   VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.raised_by_name');
    DECLARE @supplier  INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.supplier_sno') AS INT);
    DECLARE @pay       CHAR(1)       = UPPER(LEFT(JSON_VALUE(@jsonInput, '$.payment_applicable'), 1));
    DECLARE @est       DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.est_amount') AS DECIMAL(18,2));
    DECLARE @mode      VARCHAR(10)   = UPPER(JSON_VALUE(@jsonInput, '$.service_mode'));
    DECLARE @svc_vendor VARCHAR(255) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.service_vendor'))), '');
    DECLARE @exp_ret   DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.expected_return_date') AS DATE);

    IF @type NOT IN ('RETURN','SERVICE')  THROW 53001, 'request_type must be RETURN or SERVICE.', 1;
    IF @sr_item IS NULL OR @by IS NULL     THROW 53001, 'sr_item_sno and raised_by are required.', 1;
    IF @qty IS NULL OR @qty <= 0           THROW 53001, 'Quantity must be greater than 0.', 1;
    IF @reason IS NULL                      THROW 53001, 'A reason is required.', 1;
    IF @type = 'SERVICE'
    BEGIN
        IF @mode NOT IN ('OUTPASS','INSTORE') THROW 53001, 'Choose a service location: Outpass (outside) or In-store.', 1;
        IF @pay  NOT IN ('Y','N')              THROW 53001, 'Say whether payment is applicable (Yes / No).', 1;
        IF @pay = 'Y' AND (@est IS NULL OR @est <= 0) THROW 53001, 'Enter the estimated amount when payment is applicable.', 1;
        IF @mode = 'OUTPASS' AND @svc_vendor IS NULL  THROW 53001, 'Enter the repair vendor the item is going to.', 1;
    END
    ELSE SET @mode = NULL;

    DECLARE @is_store BIT = 0;
    IF EXISTS (
        SELECT 1 FROM dbo.nt_user_permissions_json up
        CROSS APPLY OPENJSON(up.screens_json) WITH (screen_id INT '$.screen_id') s
        JOIN dbo.screens sc ON sc.screen_id = s.screen_id
        WHERE up.ecno = @by AND sc.comp IN ('StoreIssuePage', 'StockIssuePage')
    ) SET @is_store = 1;

    DECLARE @asset_req_sno INT;

    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @stock_req INT, @issue_ref VARCHAR(30), @item_sno INT, @item_code VARCHAR(50), @item_name VARCHAR(255), @uom VARCHAR(20),
                @com INT, @div INT, @brn INT, @dept INT, @issued DECIMAL(18,2), @prod INT;

        SELECT @stock_req = r.request_sno, @issue_ref = r.request_no, @item_sno = l.item_sno,
               @item_code = i.item_code, @item_name = i.item_name, @uom = i.uom, @prod = i.prod_sno,
               @com = r.com_sno, @div = r.div_sno, @brn = r.brn_sno, @dept = r.dept_sno, @issued = l.issued_qty
        FROM dbo.nt_stock_request_items l WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.nt_stock_requests r  ON r.request_sno = l.request_sno
        JOIN dbo.nt_inventory_items i ON i.item_sno = l.item_sno
        JOIN dbo.product_master p     ON p.prod_sno = i.prod_sno
        JOIN dbo.subcategory_master sc ON sc.subcat_sno = p.subcat_sno AND sc.subcat_stock_type = 'Non-Regular'
        WHERE l.sr_item_sno = @sr_item AND l.issued_qty > 0;

        IF @stock_req IS NULL THROW 53002, 'This item is not a Non-Regular issued asset.', 1;

        DECLARE @reserved DECIMAL(18,2);
        SELECT @reserved = ISNULL(SUM(CASE WHEN request_type = 'RETURN'  AND status NOT IN ('Rejected','Cancelled') THEN qty
                                           WHEN request_type = 'SERVICE' AND status NOT IN ('Rejected','Cancelled','Completed') THEN qty END), 0)
        FROM dbo.nt_asset_requests WHERE sr_item_sno = @sr_item;

        IF @qty > @issued - @reserved
            THROW 53003, 'Quantity exceeds what is currently in use for this asset (some is already returned or in service).', 1;

        -- Default supplier for debit notes: given, else the supplier of the most recent GRN of this product.
        IF @supplier IS NULL
            SELECT TOP 1 @supplier = g.vendor_sno
            FROM dbo.grn_item_details gi
            JOIN dbo.grn_basic_info g ON g.grn_basic_sno = gi.grn_basic_sno AND g.is_active = 'Y'
            WHERE gi.prod_sno = @prod AND g.vendor_sno IS NOT NULL
            ORDER BY g.grn_basic_sno DESC;

        IF @type = 'RETURN' AND @supplier IS NULL
            THROW 53004, 'No supplier found for this product — choose the supplier the item is being returned to.', 1;

        -- Approval chain: DEPT stage(s) first when raised by the store, then the type's own chain.
        DECLARE @chain TABLE (seq INT IDENTITY(1,1), phase VARCHAR(5), stage_name VARCHAR(100), approver VARCHAR(50));
        IF @is_store = 1
        BEGIN
            INSERT INTO @chain (phase, stage_name, approver)
            SELECT 'DEPT', stage_name, approver_ecno FROM dbo.nt_asset_approval_config
            WHERE entity = 'DEPT' AND is_active = 'Y'
              AND (dept_sno = @dept OR (dept_sno IS NULL AND NOT EXISTS (SELECT 1 FROM dbo.nt_asset_approval_config c2 WHERE c2.entity = 'DEPT' AND c2.is_active = 'Y' AND c2.dept_sno = @dept)))
            ORDER BY stage_order;
            IF NOT EXISTS (SELECT 1 FROM @chain) THROW 53005, 'No department approver configured (nt_asset_approval_config, entity DEPT).', 1;
        END
        INSERT INTO @chain (phase, stage_name, approver)
        SELECT 'MAIN', stage_name, approver_ecno FROM dbo.nt_asset_approval_config
        WHERE entity = @type AND is_active = 'Y'
          AND (dept_sno = @dept OR (dept_sno IS NULL AND NOT EXISTS (SELECT 1 FROM dbo.nt_asset_approval_config c2 WHERE c2.entity = @type AND c2.is_active = 'Y' AND c2.dept_sno = @dept)))
        ORDER BY stage_order;
        IF NOT EXISTS (SELECT 1 FROM @chain WHERE phase = 'MAIN')
            THROW 53005, 'No approver configured for this request type (nt_asset_approval_config).', 1;

        DECLARE @yr VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @prefix VARCHAR(12) = CASE WHEN @type = 'RETURN' THEN 'ARR-' ELSE 'ASV-' END + @yr + '-';
        DECLARE @n INT;
        SELECT @n = ISNULL(MAX(TRY_CAST(RIGHT(request_no, 4) AS INT)), 0) + 1
        FROM dbo.nt_asset_requests WITH (UPDLOCK, HOLDLOCK) WHERE request_no LIKE @prefix + '%';
        DECLARE @request_no VARCHAR(30) = @prefix + RIGHT('0000' + CAST(@n AS VARCHAR(4)), 4);

        DECLARE @dc_no VARCHAR(30) = NULL;
        IF @mode = 'OUTPASS'
        BEGIN
            DECLARE @dcp VARCHAR(12) = 'DC-' + @yr + '-';
            SELECT @n = ISNULL(MAX(TRY_CAST(RIGHT(dc_no, 4) AS INT)), 0) + 1
            FROM dbo.nt_asset_requests WITH (UPDLOCK, HOLDLOCK) WHERE dc_no LIKE @dcp + '%';
            SET @dc_no = @dcp + RIGHT('0000' + CAST(@n AS VARCHAR(4)), 4);
        END

        DECLARE @first_phase VARCHAR(5), @first_appr VARCHAR(50);
        SELECT TOP 1 @first_phase = phase, @first_appr = approver FROM @chain ORDER BY seq;

        INSERT INTO dbo.nt_asset_requests (
            request_no, request_type, sr_item_sno, stock_request_sno, issue_ref, item_sno, item_code, item_name, uom,
            qty, reason, raised_by, raised_by_name, raised_role, com_sno, div_sno, brn_sno, dept_sno,
            status, current_approver_ecno, supplier_sno, payment_applicable, est_amount, service_mode, service_vendor,
            expected_return_date, dc_no, dc_date
        )
        VALUES (
            @request_no, @type, @sr_item, @stock_req, @issue_ref, @item_sno, @item_code, @item_name, @uom,
            @qty, @reason, @by, @by_name, CASE WHEN @is_store = 1 THEN 'STORE' ELSE 'DEPT' END, @com, @div, @brn, @dept,
            CASE WHEN @first_phase = 'DEPT' THEN 'Pending Dept Approval' ELSE 'Pending Approval' END,
            @first_appr, @supplier, CASE WHEN @type = 'SERVICE' THEN @pay END, @est, @mode, @svc_vendor,
            @exp_ret, @dc_no, CASE WHEN @dc_no IS NOT NULL THEN GETDATE() END
        );
        SET @asset_req_sno = SCOPE_IDENTITY();

        INSERT INTO dbo.nt_asset_request_approvals (asset_req_sno, seq, phase, stage_name, approver_ecno, status)
        SELECT @asset_req_sno, seq, phase, stage_name, approver, CASE WHEN seq = 1 THEN 'Pending' ELSE 'Waiting' END
        FROM @chain;

        INSERT INTO dbo.nt_asset_request_history (asset_req_sno, event, remarks, by_ecno)
        VALUES (@asset_req_sno,
                CASE WHEN @type = 'RETURN' THEN 'Return requested' ELSE 'Service requested' END
                  + CASE WHEN @is_store = 1 THEN ' by Store In-charge' ELSE ' by Department' END,
                @reason, @by);
        IF @dc_no IS NOT NULL
            INSERT INTO dbo.nt_asset_request_history (asset_req_sno, event, remarks, by_ecno)
            VALUES (@asset_req_sno, 'Delivery Challan created', @dc_no, @by);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT * FROM dbo.vw_nt_asset_requests WHERE asset_req_sno = @asset_req_sno;
END;
GO

-- ── sp_nt_AssetRequestAction ──────────────────────────────────────────────
-- @jsonInput: { asset_req_sno, action, by, remarks?, unit_price?, result?, technician?, dc_no? }
-- actions: APPROVE REJECT CANCEL RAISE_RETURN_ORDER GATE_OUT GATE_IN START_SERVICE COMPLETE_SERVICE
--          RAISE_DEBIT_NOTE RESERVICE
CREATE OR ALTER PROCEDURE dbo.sp_nt_AssetRequestAction
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @id      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.asset_req_sno') AS INT);
    DECLARE @action  VARCHAR(30)   = UPPER(JSON_VALUE(@jsonInput, '$.action'));
    DECLARE @by      VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.by');
    DECLARE @remarks VARCHAR(500)  = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), '');
    DECLARE @price   DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.unit_price') AS DECIMAL(18,2));
    DECLARE @result  VARCHAR(10)   = UPPER(JSON_VALUE(@jsonInput, '$.result'));
    DECLARE @tech    VARCHAR(255)  = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.technician'))), '');
    DECLARE @dc_in   VARCHAR(30)   = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.dc_no'))), '');

    IF @id IS NULL OR @action IS NULL OR @by IS NULL THROW 53010, 'asset_req_sno, action and by are required.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @type VARCHAR(10), @status VARCHAR(30), @mode VARCHAR(10), @raised_by VARCHAR(50), @qty DECIMAL(18,2),
                @dc_no VARCHAR(30), @supplier INT, @request_no VARCHAR(30), @item_sno INT, @item_name VARCHAR(255),
                @uom VARCHAR(20), @com INT, @div INT, @brn INT, @dept INT, @cycle INT;

        SELECT @type = request_type, @status = status, @mode = service_mode, @raised_by = raised_by, @qty = qty,
               @dc_no = dc_no, @supplier = supplier_sno, @request_no = request_no, @item_sno = item_sno,
               @item_name = item_name, @uom = uom, @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno,
               @cycle = cycle_no
        FROM dbo.nt_asset_requests WITH (UPDLOCK, HOLDLOCK) WHERE asset_req_sno = @id;

        IF @type IS NULL THROW 53011, 'Asset request not found.', 1;

        DECLARE @yr VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @n INT, @pfx VARCHAR(12);
        DECLARE @event VARCHAR(60) = NULL;

        IF @action IN ('APPROVE','REJECT')
        BEGIN
            IF @status NOT IN ('Pending Dept Approval','Pending Approval') THROW 53012, 'This request is not awaiting approval.', 1;
            DECLARE @cur INT, @cur_phase VARCHAR(5);
            SELECT TOP 1 @cur = approval_sno, @cur_phase = phase
            FROM dbo.nt_asset_request_approvals WHERE asset_req_sno = @id AND status = 'Pending' ORDER BY seq;
            IF @cur IS NULL THROW 53012, 'No pending approval stage.', 1;
            IF NOT EXISTS (SELECT 1 FROM dbo.nt_asset_request_approvals WHERE approval_sno = @cur AND approver_ecno = @by)
                THROW 53013, 'You are not the current approver of this request.', 1;

            IF @action = 'REJECT'
            BEGIN
                IF @remarks IS NULL THROW 53014, 'A reason is required to reject.', 1;
                UPDATE dbo.nt_asset_request_approvals SET status = 'Rejected', acted_by = @by, acted_at = GETDATE(), remarks = @remarks WHERE approval_sno = @cur;
                UPDATE dbo.nt_asset_request_approvals SET status = 'Skipped' WHERE asset_req_sno = @id AND status = 'Waiting';
                UPDATE dbo.nt_asset_requests SET status = 'Rejected', current_approver_ecno = NULL, reject_reason = @remarks, updated_at = GETDATE() WHERE asset_req_sno = @id;
                SET @event = 'Rejected';
            END
            ELSE
            BEGIN
                UPDATE dbo.nt_asset_request_approvals SET status = 'Approved', acted_by = @by, acted_at = GETDATE(), remarks = @remarks WHERE approval_sno = @cur;
                DECLARE @next INT, @next_phase VARCHAR(5), @next_appr VARCHAR(50);
                SELECT TOP 1 @next = approval_sno, @next_phase = phase, @next_appr = approver_ecno
                FROM dbo.nt_asset_request_approvals WHERE asset_req_sno = @id AND status = 'Waiting' ORDER BY seq;
                IF @next IS NULL
                    UPDATE dbo.nt_asset_requests SET status = 'Approved', current_approver_ecno = NULL, updated_at = GETDATE() WHERE asset_req_sno = @id;
                ELSE
                BEGIN
                    UPDATE dbo.nt_asset_request_approvals SET status = 'Pending' WHERE approval_sno = @next;
                    UPDATE dbo.nt_asset_requests
                    SET status = CASE WHEN @next_phase = 'DEPT' THEN 'Pending Dept Approval' ELSE 'Pending Approval' END,
                        current_approver_ecno = @next_appr, updated_at = GETDATE()
                    WHERE asset_req_sno = @id;
                END
                SET @event = CASE WHEN @cur_phase = 'DEPT' THEN 'Department approved' ELSE 'Approved' END;
            END
        END
        ELSE IF @action = 'CANCEL'
        BEGIN
            IF @status NOT IN ('Pending Dept Approval','Pending Approval') THROW 53012, 'Only a request still awaiting approval can be cancelled.', 1;
            IF @raised_by <> @by THROW 53013, 'Only the person who raised the request can cancel it.', 1;
            UPDATE dbo.nt_asset_request_approvals SET status = 'Skipped' WHERE asset_req_sno = @id AND status IN ('Waiting','Pending');
            UPDATE dbo.nt_asset_requests SET status = 'Cancelled', current_approver_ecno = NULL, updated_at = GETDATE() WHERE asset_req_sno = @id;
            SET @event = 'Cancelled';
        END
        ELSE IF @action = 'RAISE_RETURN_ORDER'
        BEGIN
            IF @type <> 'RETURN' OR @status <> 'Approved' THROW 53012, 'A Return Order can only be raised for an approved return request.', 1;
            SET @pfx = 'RO-' + @yr + '-';
            SELECT @n = ISNULL(MAX(TRY_CAST(RIGHT(return_order_no, 4) AS INT)), 0) + 1
            FROM dbo.nt_asset_requests WITH (UPDLOCK, HOLDLOCK) WHERE return_order_no LIKE @pfx + '%';
            UPDATE dbo.nt_asset_requests
            SET status = 'Return Order Raised', return_order_no = @pfx + RIGHT('0000' + CAST(@n AS VARCHAR(4)), 4),
                return_order_date = GETDATE(), updated_at = GETDATE()
            WHERE asset_req_sno = @id;
            SET @event = 'Return Order raised';
        END
        ELSE IF @action = 'GATE_OUT'
        BEGIN
            IF NOT ((@type = 'RETURN' AND @status = 'Return Order Raised') OR (@type = 'SERVICE' AND @mode = 'OUTPASS' AND @status = 'Approved'))
                THROW 53012, 'Gate pass OUT is not allowed at this stage.', 1;
            SET @pfx = 'GPO-' + @yr + '-';
            SELECT @n = ISNULL(MAX(TRY_CAST(RIGHT(gate_out_no, 4) AS INT)), 0) + 1
            FROM dbo.nt_asset_requests WITH (UPDLOCK, HOLDLOCK) WHERE gate_out_no LIKE @pfx + '%';
            DECLARE @gpo VARCHAR(30) = @pfx + RIGHT('0000' + CAST(@n AS VARCHAR(4)), 4);
            IF @dc_no IS NULL
            BEGIN
                DECLARE @dcp VARCHAR(12) = 'DC-' + @yr + '-';
                SELECT @n = ISNULL(MAX(TRY_CAST(RIGHT(dc_no, 4) AS INT)), 0) + 1
                FROM dbo.nt_asset_requests WITH (UPDLOCK, HOLDLOCK) WHERE dc_no LIKE @dcp + '%';
                SET @dc_no = @dcp + RIGHT('0000' + CAST(@n AS VARCHAR(4)), 4);
            END
            UPDATE dbo.nt_asset_requests
            SET status = CASE WHEN @type = 'RETURN' THEN 'Goods Returned' ELSE 'At Vendor' END,
                gate_out_no = @gpo, gate_out_at = GETDATE(), dc_no = @dc_no, dc_date = ISNULL(dc_date, GETDATE()), updated_at = GETDATE()
            WHERE asset_req_sno = @id;
            SET @event = 'Gate pass OUT ' + @gpo + ' (DC ' + @dc_no + ')';
        END
        ELSE IF @action = 'GATE_IN'
        BEGIN
            IF NOT (@type = 'SERVICE' AND @mode = 'OUTPASS' AND @status = 'At Vendor') THROW 53012, 'Gate pass IN is not allowed at this stage.', 1;
            IF @dc_in IS NULL OR @dc_in <> @dc_no THROW 53015, 'Enter the same DC number that went out with the item.', 1;
            SET @pfx = 'GPI-' + @yr + '-';
            SELECT @n = ISNULL(MAX(TRY_CAST(RIGHT(gate_in_no, 4) AS INT)), 0) + 1
            FROM dbo.nt_asset_requests WITH (UPDLOCK, HOLDLOCK) WHERE gate_in_no LIKE @pfx + '%';
            DECLARE @gpi VARCHAR(30) = @pfx + RIGHT('0000' + CAST(@n AS VARCHAR(4)), 4);
            UPDATE dbo.nt_asset_requests SET status = 'Received', gate_in_no = @gpi, gate_in_at = GETDATE(), updated_at = GETDATE() WHERE asset_req_sno = @id;
            SET @event = 'Gate pass IN ' + @gpi + ' (DC ' + @dc_no + ')';
        END
        ELSE IF @action = 'START_SERVICE'
        BEGIN
            IF NOT (@type = 'SERVICE' AND @mode = 'INSTORE' AND @status = 'Approved') THROW 53012, 'In-store service can only start on an approved in-store request.', 1;
            UPDATE dbo.nt_asset_requests SET status = 'In Progress', service_vendor = ISNULL(@tech, service_vendor), updated_at = GETDATE() WHERE asset_req_sno = @id;
            SET @event = 'In-store service started';
        END
        ELSE IF @action = 'COMPLETE_SERVICE'
        BEGIN
            IF @type <> 'SERVICE' OR @status NOT IN ('In Progress','Received') THROW 53012, 'Service cannot be completed at this stage.', 1;
            IF @result NOT IN ('OK','NOT_OK') THROW 53016, 'Choose the result: OK or NOT_OK.', 1;
            IF @result = 'NOT_OK' AND @remarks IS NULL THROW 53014, 'Enter what is wrong when the result is not OK.', 1;
            IF @status = 'In Progress'
            BEGIN
                IF @result = 'OK'
                    UPDATE dbo.nt_asset_requests SET status = 'Completed', qc_result = 'OK', completed_at = GETDATE(), updated_at = GETDATE() WHERE asset_req_sno = @id;
                ELSE
                    UPDATE dbo.nt_asset_requests SET rework_count = rework_count + 1, qc_result = 'NOT_OK', updated_at = GETDATE() WHERE asset_req_sno = @id;
                SET @event = CASE WHEN @result = 'OK' THEN 'Service completed OK' ELSE 'Service check NOT OK — re-service' END;
            END
            ELSE
            BEGIN
                SET @pfx = 'SGRN-' + @yr + '-';
                SELECT @n = ISNULL(MAX(TRY_CAST(RIGHT(service_receipt_no, 4) AS INT)), 0) + 1
                FROM dbo.nt_asset_requests WITH (UPDLOCK, HOLDLOCK) WHERE service_receipt_no LIKE @pfx + '%';
                UPDATE dbo.nt_asset_requests
                SET service_receipt_no = @pfx + RIGHT('0000' + CAST(@n AS VARCHAR(4)), 4), qc_result = @result,
                    status = CASE WHEN @result = 'OK' THEN 'Completed' ELSE 'QC Failed' END,
                    completed_at = CASE WHEN @result = 'OK' THEN GETDATE() END, updated_at = GETDATE()
                WHERE asset_req_sno = @id;
                SET @event = CASE WHEN @result = 'OK' THEN 'GRN against DC — quality OK, back to Assets' ELSE 'GRN against DC — quality NOT OK' END;
            END
        END
        ELSE IF @action = 'RAISE_DEBIT_NOTE'
        BEGIN
            IF NOT ((@type = 'RETURN' AND @status = 'Goods Returned') OR (@type = 'SERVICE' AND @status = 'QC Failed'))
                THROW 53012, 'A debit note can only be raised after goods are returned, or after a failed quality check.', 1;
            IF @supplier IS NULL THROW 53004, 'No supplier on this request — cannot raise a debit note.', 1;
            IF @price IS NULL SELECT @price = ISNULL(cost_price, 0) FROM dbo.nt_inventory_items WHERE item_sno = @item_sno;

            DECLARE @prefix VARCHAR(70) = 'DN-' + @request_no + '-';
            DECLARE @seq INT;
            SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(debit_note_no, 3) AS INT)), 0) + 1
            FROM dbo.debit_note_basic_info WITH (UPDLOCK, HOLDLOCK) WHERE debit_note_no LIKE @prefix + '%';
            DECLARE @dn_no VARCHAR(60) = @prefix + RIGHT('000' + CAST(@seq AS VARCHAR(3)), 3);
            DECLARE @prod_sno INT, @prod_name VARCHAR(255);
            SELECT @prod_sno = prod_sno, @prod_name = item_name FROM dbo.nt_inventory_items WHERE item_sno = @item_sno;

            INSERT INTO dbo.debit_note_basic_info (
                debit_note_no, grn_basic_sno, po_basic_sno, vendor_sno, com_sno, div_sno, brn_sno, dept_sno,
                debit_note_date, total_qty, total_amount, remarks, status, is_active, created_by, created_date, asset_request_sno
            )
            VALUES (
                @dn_no, NULL, NULL, @supplier, @com, @div, @brn, @dept,
                GETDATE(), @qty, @qty * @price,
                LEFT(ISNULL(@remarks, CASE WHEN @type = 'RETURN' THEN 'Asset returned to supplier' ELSE 'Service quality check failed' END), 500),
                'Raised', 'Y', LEFT(@by, 20), GETDATE(), @id
            );
            DECLARE @dn INT = SCOPE_IDENTITY();

            INSERT INTO dbo.debit_note_item_details (debit_note_sno, prod_sno, prod_name, unit_name, reason_type, qty, unit_price, amount, remarks, is_active)
            VALUES (@dn, @prod_sno, @item_name, @uom, CASE WHEN @type = 'RETURN' THEN 'Return' ELSE 'Damage' END, @qty, @price, @qty * @price, @remarks, 'Y');

            INSERT INTO dbo.debit_note_history_data (event_type, debit_note_sno, po_basic_sno, grn_basic_sno, remarks, status_by)
            VALUES ('Debit Note Raised', @dn, NULL, NULL, @remarks, @by);

            UPDATE dbo.nt_asset_requests
            SET debit_note_sno = @dn,
                status = CASE WHEN @type = 'RETURN' THEN 'Closed' ELSE 'Debit Note Raised' END,
                completed_at = CASE WHEN @type = 'RETURN' THEN GETDATE() ELSE completed_at END,
                updated_at = GETDATE()
            WHERE asset_req_sno = @id;
            SET @event = 'Debit Note ' + @dn_no + ' raised';
        END
        ELSE IF @action = 'RESERVICE'
        BEGIN
            IF NOT (@type = 'SERVICE' AND @status = 'Debit Note Raised') THROW 53012, 'Re-service is offered after a debit note on a failed service.', 1;
            DECLARE @dcp2 VARCHAR(12) = 'DC-' + @yr + '-', @new_dc VARCHAR(30) = NULL;
            IF @mode = 'OUTPASS'
            BEGIN
                SELECT @n = ISNULL(MAX(TRY_CAST(RIGHT(dc_no, 4) AS INT)), 0) + 1
                FROM dbo.nt_asset_requests WITH (UPDLOCK, HOLDLOCK) WHERE dc_no LIKE @dcp2 + '%';
                SET @new_dc = @dcp2 + RIGHT('0000' + CAST(@n AS VARCHAR(4)), 4);
            END
            UPDATE dbo.nt_asset_requests
            SET status = 'Approved', cycle_no = cycle_no + 1, qc_result = NULL, service_receipt_no = NULL,
                gate_out_no = NULL, gate_out_at = NULL, gate_in_no = NULL, gate_in_at = NULL,
                dc_no = ISNULL(@new_dc, dc_no), dc_date = CASE WHEN @new_dc IS NOT NULL THEN GETDATE() ELSE dc_date END,
                updated_at = GETDATE()
            WHERE asset_req_sno = @id;
            SET @event = 'Re-service started (cycle ' + CAST(@cycle + 1 AS VARCHAR(5)) + ')';
        END
        ELSE THROW 53010, 'Unknown action.', 1;

        INSERT INTO dbo.nt_asset_request_history (asset_req_sno, event, remarks, by_ecno) VALUES (@id, @event, @remarks, @by);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT * FROM dbo.vw_nt_asset_requests WHERE asset_req_sno = @id;
END;
GO

-- ── Screen registration: Asset Management in the GRN group (6), after GRN (20) ──
IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'AssetManagementPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Asset Management', 'S15', 'AssetManagementPage', 'Boxes', 6, 21, 'Y');
GO

DECLARE @screen_id INT, @json NVARCHAR(200);
SELECT @screen_id = screen_id FROM dbo.screens WHERE comp = 'AssetManagementPage';
SET @json = N'{"ecno":"KTM1148","screen_id":' + CAST(@screen_id AS VARCHAR(10)) + N',"permission_ids":[2,3,4,5]}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
SET @json = N'{"ecno":"KTM1004","screen_id":' + CAST(@screen_id AS VARCHAR(10)) + N',"permission_ids":[2,3,4]}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
GO
