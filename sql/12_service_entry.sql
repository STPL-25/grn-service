-- ============================================================
-- Service Entry — GRN-equivalent for services
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : new grn-service/src/serviceentry module (port 8084, mounted at
--            /api/service_entry)
--
-- Why this is needed
-- ------------------
-- Service_Procurement_Flow.pdf: services don't get received/counted like a
-- GRN — they get a usage/consumption CONFIRMATION for a period. Mirrors
-- grn_basic_info's v2 shape (org cols, workflow_types_id/current_approver_id/
-- status) — confirmed live via direct DB query as the schema GRN actually
-- uses today (grn-service/sql/07_grn_procs_v2.sql). Unlike GRN, which has no
-- approval step, Service Entry needs one for Type 2's variance-exceeded
-- escalation, so approval columns are real here, not vestigial.
--
-- Variance model: each po_item_details line set at Service-PO-creation time
-- carries a budgeted/expected amount (net_cost). Each Service Entry line's
-- confirmed_amount is compared against that same line's po_amount snapshot;
-- variance_pct = (confirmed - po_amount) / po_amount * 100, rolled up to the
-- header as the weighted total. Within dbo.po_request_info.variance_tolerance_pct
-- (Type 2 only) -> auto-approved; NULL tolerance or Type 1/3 -> auto-approved
-- (no variance concept); exceeded -> routed to a human approval step
-- (entity_type = 'ServiceEntry', same bespoke-approval pattern as PR/PO).
--
-- po_request_info.consumed_amount is incremented by each entry's total
-- confirmed_amount, tracking ceiling consumption for Type 2 as the design doc
-- asks ("PO ceiling & YTD consumption tracked for next cycle").
-- ============================================================

IF OBJECT_ID('dbo.service_entry_info', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_entry_info (
        service_entry_sno   INT IDENTITY(1,1) PRIMARY KEY,
        service_entry_no    INT           NULL,
        com_sno              INT           NULL,
        div_sno              INT           NULL,
        brn_sno              INT           NULL,
        dept_sno             INT           NULL,
        po_basic_sno         INT           NOT NULL,
        vendor_sno           INT           NULL,
        period_from          DATE          NULL,
        period_to            DATE          NULL,
        usage_reference      VARCHAR(200)  NULL,
        confirmed_amount     DECIMAL(18,2) NOT NULL DEFAULT 0,
        variance_pct         DECIMAL(9,4)  NULL,
        variance_status      VARCHAR(20)   NULL,   -- WITHIN_TOLERANCE | EXCEEDED | N/A
        accept_reject_flag   VARCHAR(10)   NOT NULL DEFAULT 'Accepted',
        remarks              VARCHAR(500)  NULL,
        is_active            CHAR(1)       NOT NULL DEFAULT 'Y',
        workflow_types_id    INT           NULL,
        current_approver_id  VARCHAR(20)   NULL,
        status               VARCHAR(20)   NOT NULL DEFAULT 'Pending',  -- Pending | Approved | Rejected
        approved_by          VARCHAR(20)   NULL,
        approved_at          DATETIME      NULL,
        approval_comments    VARCHAR(500)  NULL,
        created_by           VARCHAR(20)   NULL,
        created_date         DATETIME      NOT NULL DEFAULT GETDATE(),
        modified_by          VARCHAR(20)   NULL,
        modified_date        DATETIME      NULL,
        CONSTRAINT FK_service_entry_info_po
            FOREIGN KEY (po_basic_sno) REFERENCES dbo.po_request_info (po_basic_sno)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_service_entry_info_po' AND object_id = OBJECT_ID('dbo.service_entry_info'))
    CREATE INDEX IX_service_entry_info_po ON dbo.service_entry_info (po_basic_sno);
GO

IF OBJECT_ID('dbo.service_entry_item_details', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_entry_item_details (
        service_entry_item_sno INT IDENTITY(1,1) PRIMARY KEY,
        service_entry_sno       INT           NOT NULL,
        po_item_sno              INT           NOT NULL,
        service_sno               INT           NULL,
        uom_sno                    INT           NULL,
        billed_qty                 DECIMAL(10,3) NULL,
        unit_price                 DECIMAL(18,2) NULL,
        po_amount                  DECIMAL(18,2) NOT NULL DEFAULT 0,
        confirmed_amount           DECIMAL(18,2) NOT NULL DEFAULT 0,
        diff_amount                DECIMAL(18,2) NOT NULL DEFAULT 0,
        accept_reject_flag         VARCHAR(10)   NOT NULL DEFAULT 'Accepted',
        remarks                    VARCHAR(500)  NULL,
        created_by                 VARCHAR(20)   NULL,
        created_date               DATETIME      NOT NULL DEFAULT GETDATE(),
        is_active                  CHAR(1)       NOT NULL DEFAULT 'Y',
        CONSTRAINT FK_service_entry_item_details_header
            FOREIGN KEY (service_entry_sno) REFERENCES dbo.service_entry_info (service_entry_sno),
        CONSTRAINT FK_service_entry_item_details_po_item
            FOREIGN KEY (po_item_sno) REFERENCES dbo.po_item_details (po_item_sno)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_service_entry_item_details_header' AND object_id = OBJECT_ID('dbo.service_entry_item_details'))
    CREATE INDEX IX_service_entry_item_details_header ON dbo.service_entry_item_details (service_entry_sno);
GO

-- entity_master seed row for the approval-side workflow lookup
IF NOT EXISTS (SELECT 1 FROM dbo.entity_master WHERE entity_code = 'ServiceEntry')
    INSERT INTO dbo.entity_master (entity_name, entity_code, entity_desc, is_active, created_by)
    VALUES (N'Service Entry', N'ServiceEntry', NULL, 'Y', N'system');
GO

-- ============================================================
-- sp_nt_CreateServiceEntry
-- @jsonInput: { po_basic_sno, vendor_sno, period_from, period_to,
--   usage_reference, created_by, com_sno, div_sno, brn_sno, dept_sno,
--   items: [{ po_item_sno, service_sno?, uom_sno?, billed_qty?, unit_price?,
--     confirmed_amount, remarks? }] }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateServiceEntry', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateServiceEntry;
GO
CREATE PROCEDURE dbo.sp_nt_CreateServiceEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @po_basic_sno    INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT);
        DECLARE @vendor_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @period_from     DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_from') AS DATE);
        DECLARE @period_to       DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_to') AS DATE);
        DECLARE @usage_reference VARCHAR(200)  = JSON_VALUE(@jsonInput, '$.usage_reference');
        DECLARE @created_by      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
        DECLARE @com_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
        DECLARE @div_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
        DECLARE @brn_sno         INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
        DECLARE @dept_sno        INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
        DECLARE @items           NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

        IF @po_basic_sno IS NULL OR @created_by IS NULL
            THROW 53001, 'po_basic_sno and created_by are required.', 1;

        IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
            THROW 53002, 'At least one item is required.', 1;

        DECLARE @variance_tolerance_pct DECIMAL(5,2), @service_type_sno INT, @po_status VARCHAR(10);
        SELECT @variance_tolerance_pct = variance_tolerance_pct,
               @service_type_sno = service_type_sno,
               @po_status = status
        FROM dbo.po_request_info
        WHERE po_basic_sno = @po_basic_sno;

        IF @service_type_sno IS NULL
            THROW 53003, 'po_basic_sno does not reference a Service PO.', 1;

        IF @po_status <> 'A'
            THROW 53004, 'Service PO must be approved before a Service Entry can be raised against it.', 1;

        -- Snapshot each item's budgeted amount (po_item_details.net_cost) so
        -- variance is measured against what the PO actually agreed, not a
        -- moving target.
        DECLARE @lineItems TABLE (
            po_item_sno    INT,
            service_sno    INT,
            uom_sno        INT,
            billed_qty     DECIMAL(10,3),
            unit_price     DECIMAL(18,2),
            po_amount      DECIMAL(18,2),
            confirmed_amount DECIMAL(18,2),
            remarks        VARCHAR(500)
        );

        INSERT INTO @lineItems (po_item_sno, service_sno, uom_sno, billed_qty, unit_price, po_amount, confirmed_amount, remarks)
        SELECT
            TRY_CAST(JSON_VALUE(j.value, '$.po_item_sno') AS INT),
            TRY_CAST(JSON_VALUE(j.value, '$.service_sno') AS INT),
            TRY_CAST(JSON_VALUE(j.value, '$.uom_sno') AS INT),
            TRY_CAST(JSON_VALUE(j.value, '$.billed_qty') AS DECIMAL(10,3)),
            TRY_CAST(JSON_VALUE(j.value, '$.unit_price') AS DECIMAL(18,2)),
            ISNULL(pid.net_cost, 0),
            ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.confirmed_amount') AS DECIMAL(18,2)), 0),
            JSON_VALUE(j.value, '$.remarks')
        FROM OPENJSON(@items) j
        JOIN dbo.po_item_details pid ON pid.po_item_sno = TRY_CAST(JSON_VALUE(j.value, '$.po_item_sno') AS INT);

        DECLARE @totalConfirmed DECIMAL(18,2), @totalBudgeted DECIMAL(18,2);
        SELECT @totalConfirmed = SUM(confirmed_amount), @totalBudgeted = SUM(po_amount) FROM @lineItems;

        DECLARE @variance_pct DECIMAL(9,4) = NULL, @variance_status VARCHAR(20) = 'N/A';
        DECLARE @status VARCHAR(20) = 'Approved';
        DECLARE @workflow_types_id INT = NULL, @current_approver_id VARCHAR(20) = NULL;

        IF @variance_tolerance_pct IS NOT NULL AND ISNULL(@totalBudgeted, 0) > 0
        BEGIN
            SET @variance_pct = (@totalConfirmed - @totalBudgeted) / @totalBudgeted * 100.0;

            IF ABS(@variance_pct) > @variance_tolerance_pct
            BEGIN
                SET @variance_status = 'EXCEEDED';
                SET @status = 'Pending';

                DECLARE @workflow_id INT;
                SELECT @workflow_id = wt.workflow_id, @workflow_types_id = wt.workflow_types_id
                FROM dbo.workflow_types wt
                INNER JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id
                WHERE wt.brn_sno = @brn_sno AND wt.dept_sno = @dept_sno AND wt.com_sno = @com_sno AND wt.div_sno = @div_sno
                  AND awm.entity_type = 'ServiceEntry';

                IF @workflow_types_id IS NULL
                    THROW 53005, 'No ServiceEntry workflow configuration found for this branch and department (variance exceeded tolerance).', 1;

                SELECT @current_approver_id = JSON_VALUE(s2.value, '$.approver_ecno')
                FROM dbo.vw_workflow_stages AS ws
                CROSS APPLY OPENJSON(ws.stages_json) AS s
                CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) AS s2
                WHERE ws.workflow_types_id = @workflow_types_id
                  AND s.[key] = '0' AND s2.[key] = '0';

                IF @current_approver_id IS NULL
                    THROW 53006, 'No approver found for the first stage of the ServiceEntry workflow.', 1;
            END
            ELSE
            BEGIN
                SET @variance_status = 'WITHIN_TOLERANCE';
            END
        END

        DECLARE @service_entry_no INT;
        SELECT @service_entry_no = ISNULL(MAX(service_entry_no), 0) + 1 FROM dbo.service_entry_info;

        INSERT INTO dbo.service_entry_info (
            service_entry_no, com_sno, div_sno, brn_sno, dept_sno, po_basic_sno, vendor_sno,
            period_from, period_to, usage_reference, confirmed_amount, variance_pct, variance_status,
            accept_reject_flag, is_active, workflow_types_id, current_approver_id, status,
            created_by, created_date
        )
        VALUES (
            @service_entry_no, @com_sno, @div_sno, @brn_sno, @dept_sno, @po_basic_sno, @vendor_sno,
            @period_from, @period_to, @usage_reference, ISNULL(@totalConfirmed, 0), @variance_pct, @variance_status,
            'Accepted', 'Y', @workflow_types_id, @current_approver_id, @status,
            @created_by, GETDATE()
        );

        DECLARE @service_entry_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.service_entry_item_details (
            service_entry_sno, po_item_sno, service_sno, uom_sno, billed_qty, unit_price,
            po_amount, confirmed_amount, diff_amount, accept_reject_flag, remarks, created_by, created_date, is_active
        )
        SELECT
            @service_entry_sno, po_item_sno, service_sno, uom_sno, billed_qty, unit_price,
            po_amount, confirmed_amount, (confirmed_amount - po_amount), 'Accepted', remarks, @created_by, GETDATE(), 'Y'
        FROM @lineItems;

        -- Track ceiling consumption
        UPDATE dbo.po_request_info
        SET consumed_amount = ISNULL(consumed_amount, 0) + ISNULL(@totalConfirmed, 0)
        WHERE po_basic_sno = @po_basic_sno;

        COMMIT TRANSACTION;

        SELECT
            @service_entry_sno   AS service_entry_sno,
            @service_entry_no    AS service_entry_no,
            @status               AS status,
            @variance_pct         AS variance_pct,
            @variance_status      AS variance_status,
            'SUCCESS'             AS result;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- sp_nt_ApproveServiceEntry — variance-exceeded human approval step
-- @jsonInput: { service_entry_sno, approved_by, comments, action }
-- Single-stage (Service Entry only escalates once, to one approver) — no
-- approval_stages array needed unlike PR/PO/ServicePO's multi-stage chains.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ApproveServiceEntry', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_ApproveServiceEntry;
GO
CREATE PROCEDURE dbo.sp_nt_ApproveServiceEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @service_entry_sno INT          = TRY_CAST(JSON_VALUE(@jsonInput, '$.service_entry_sno') AS INT);
        DECLARE @approved_by       VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.approved_by');
        DECLARE @comments          VARCHAR(500) = JSON_VALUE(@jsonInput, '$.comments');
        DECLARE @action            VARCHAR(20)  = LOWER(ISNULL(JSON_VALUE(@jsonInput, '$.action'), ''));

        IF @service_entry_sno IS NULL OR @approved_by IS NULL
            THROW 53010, 'service_entry_sno and approved_by are required.', 1;

        IF @action NOT IN ('approve', 'reject')
            THROW 53011, 'action must be ''approve'' or ''reject''.', 1;

        IF NOT EXISTS (SELECT 1 FROM dbo.service_entry_info WHERE service_entry_sno = @service_entry_sno AND status = 'Pending')
            THROW 53012, 'Service Entry not found or not pending approval.', 1;

        UPDATE dbo.service_entry_info
        SET status = CASE WHEN @action = 'approve' THEN 'Approved' ELSE 'Rejected' END,
            current_approver_id = NULL,
            approved_by = @approved_by,
            approved_at = GETDATE(),
            approval_comments = @comments
        WHERE service_entry_sno = @service_entry_sno;

        -- A rejected entry's confirmed amount should not count against the
        -- ceiling any more.
        IF @action = 'reject'
        BEGIN
            UPDATE p
            SET p.consumed_amount = p.consumed_amount - se.confirmed_amount
            FROM dbo.po_request_info p
            JOIN dbo.service_entry_info se ON se.po_basic_sno = p.po_basic_sno
            WHERE se.service_entry_sno = @service_entry_sno;
        END

        SELECT
            @service_entry_sno AS service_entry_sno,
            CASE WHEN @action = 'approve' THEN 'Approved' ELSE 'Rejected' END AS status,
            @approved_by AS approved_by,
            GETDATE() AS approved_at,
            'SUCCESS' AS result;
    END TRY
    BEGIN CATCH
        SELECT 'ERROR' AS result, ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
    END CATCH
END;
GO

-- ============================================================
-- sp_nt_GetPendingServicePOsForServiceEntry — approved Standing/one-time
-- Service POs within validity, eligible for a new Service Entry.
-- @jsonInput optional: { vendor_sno? }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetPendingServicePOsForServiceEntry', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPendingServicePOsForServiceEntry;
GO
CREATE PROCEDURE dbo.sp_nt_GetPendingServicePOsForServiceEntry
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @vendor_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @vendor_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);

    SELECT
        p.po_basic_sno,
        p.po_df_no AS po_no,
        p.vendor_sno,
        k.company_name AS vendor_name,
        p.po_type,
        p.service_type_sno,
        st.service_type_code,
        st.service_type_name,
        p.validity_from,
        p.validity_to,
        p.ceiling_amount,
        p.consumed_amount,
        p.variance_tolerance_pct,
        p.com_sno, p.div_sno, p.brn_sno, p.dept_sno,
        (
            SELECT pid.po_item_sno, pid.service_sno, sm.service_name, pid.unit_name, pid.net_cost
            FROM dbo.po_item_details pid
            LEFT JOIN dbo.service_master sm ON sm.service_sno = pid.service_sno
            -- po_item_details.is_active uses '1'/'0' (see 07_po_service_extensions.sql's note)
            WHERE pid.po_basic_sno = p.po_basic_sno AND pid.is_active = '1' AND pid.po_section = 'SERVICE'
            FOR JSON PATH
        ) AS items
    FROM dbo.po_request_info p
    LEFT JOIN dbo.service_type_master st ON st.service_type_sno = p.service_type_sno
    LEFT JOIN dbo.kyc_basic_info k        ON k.kyc_basic_info_sno = p.vendor_sno
    WHERE p.service_type_sno IS NOT NULL
      AND p.status = 'A'
      AND p.is_active = 'Y'
      AND (@vendor_sno IS NULL OR p.vendor_sno = @vendor_sno)
    ORDER BY p.po_basic_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetServiceEntriesByPO
-- @jsonInput: { po_basic_sno }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetServiceEntriesByPO', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetServiceEntriesByPO;
GO
CREATE PROCEDURE dbo.sp_nt_GetServiceEntriesByPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT);

    SELECT
        se.service_entry_sno, se.service_entry_no, se.po_basic_sno, p.po_df_no AS po_no,
        se.vendor_sno, k.company_name AS vendor_name,
        se.period_from, se.period_to, se.usage_reference,
        se.confirmed_amount, se.variance_pct, se.variance_status,
        se.status, se.current_approver_id, se.approved_by, se.approved_at,
        se.created_by, se.created_date,
        (
            SELECT sei.service_entry_item_sno, sei.po_item_sno, sei.service_sno, sm.service_name,
                   sei.billed_qty, sei.unit_price, sei.po_amount, sei.confirmed_amount, sei.diff_amount
            FROM dbo.service_entry_item_details sei
            LEFT JOIN dbo.service_master sm ON sm.service_sno = sei.service_sno
            WHERE sei.service_entry_sno = se.service_entry_sno AND sei.is_active = 'Y'
            FOR JSON PATH
        ) AS items
    FROM dbo.service_entry_info se
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = se.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = se.vendor_sno
    WHERE se.po_basic_sno = @po_basic_sno AND se.is_active = 'Y'
    ORDER BY se.service_entry_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetAllServiceEntries — includes the logged-in approver's pending queue
-- @jsonInput optional: { status?, Ecno? }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetAllServiceEntries', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetAllServiceEntries;
GO
CREATE PROCEDURE dbo.sp_nt_GetAllServiceEntries
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL, @Ecno VARCHAR(50) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @status = JSON_VALUE(@jsonInput, '$.status');
        SET @Ecno = JSON_VALUE(@jsonInput, '$.Ecno');
    END

    SELECT
        se.service_entry_sno, se.service_entry_no, se.po_basic_sno, p.po_df_no AS po_no,
        se.vendor_sno, k.company_name AS vendor_name,
        se.period_from, se.period_to, se.usage_reference,
        se.confirmed_amount, se.variance_pct, se.variance_status,
        se.status, se.current_approver_id, se.approved_by, se.approved_at,
        se.created_by, se.created_date,
        (
            SELECT sei.service_entry_item_sno, sei.po_item_sno, sei.service_sno, sm.service_name,
                   sei.billed_qty, sei.unit_price, sei.po_amount, sei.confirmed_amount, sei.diff_amount
            FROM dbo.service_entry_item_details sei
            LEFT JOIN dbo.service_master sm ON sm.service_sno = sei.service_sno
            WHERE sei.service_entry_sno = se.service_entry_sno AND sei.is_active = 'Y'
            FOR JSON PATH
        ) AS items
    FROM dbo.service_entry_info se
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = se.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = se.vendor_sno
    WHERE se.is_active = 'Y'
      AND (@status IS NULL OR se.status = @status)
      AND (@Ecno IS NULL OR se.current_approver_id = @Ecno)
    ORDER BY se.service_entry_sno DESC;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT name FROM sys.procedures WHERE name LIKE 'sp_nt_%ServiceEntry%';
-- ============================================================
