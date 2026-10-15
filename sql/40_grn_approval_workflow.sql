-- ============================================================
-- 40_grn_approval_workflow.sql   (Non_trade_Dev)
--
-- GRN approval gate.
--   * After sp_nt_CreateGRN the service calls sp_nt_SubmitGRNForApproval, which looks up the
--     'GRN' workflow for the GRN's company/division/branch/department (same lookup as ServicePO).
--       - workflow found  -> status 'Pending Approval', current_approver_id = first approver
--       - none configured -> status 'Approved' straight away (so receiving is never blocked
--                            while no GRN workflow exists - add one on the Approval Workflows screen)
--   * Inventory / FIFO batch / auto store requisition posting happens only when the GRN is Approved
--     (done by the service after sp_nt_ApproveGRN reports FINAL).
--   * Reject: status 'Rejected', lines deactivated (frees the PO pending qty), gate entry back to 'In',
--     pending excess requests closed.
--   * Legacy rows (status 'Received', created before this gate) are treated as already approved.
-- Re-runnable.
-- ============================================================

IF COL_LENGTH('dbo.grn_basic_info', 'approved_at') IS NULL
    ALTER TABLE dbo.grn_basic_info ADD approved_at DATETIME NULL;
GO

IF OBJECT_ID('dbo.grn_approval_history', 'U') IS NULL
CREATE TABLE dbo.grn_approval_history (
    history_sno  INT IDENTITY(1,1) PRIMARY KEY,
    grn_basic_sno INT NOT NULL,
    action_type  VARCHAR(20) NOT NULL,      -- SUBMITTED / APPROVED / REJECTED / AUTO_APPROVED
    status_by    VARCHAR(30) NULL,
    comment      NVARCHAR(500) NULL,
    created_at   DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_grn_approval_history_grn')
    CREATE INDEX IX_grn_approval_history_grn ON dbo.grn_approval_history (grn_basic_sno);
GO

-- ── submit ──────────────────────────────────────────────────────────────────
-- @jsonInput: { grn_basic_sno, created_by }
CREATE OR ALTER PROCEDURE dbo.sp_nt_SubmitGRNForApproval
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn INT = JSON_VALUE(@jsonInput, '$.grn_basic_sno'),
            @by  VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by');
    DECLARE @com INT, @div INT, @brn INT, @dept INT, @wf INT, @first VARCHAR(30);

    SELECT @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno
    FROM dbo.grn_basic_info WHERE grn_basic_sno = @grn;
    IF @@ROWCOUNT = 0 THROW 53201, 'GRN not found.', 1;

    SELECT TOP 1 @wf = wt.workflow_types_id
    FROM dbo.workflow_types wt
    JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id AND awm.is_active = 'Y'
    WHERE wt.is_active = 'Y' AND awm.entity_type = 'GRN'
      AND wt.com_sno = @com AND wt.div_sno = @div AND wt.brn_sno = @brn AND wt.dept_sno = @dept
    ORDER BY wt.workflow_types_id DESC;

    IF @wf IS NOT NULL
        SELECT TOP 1 @first = JSON_VALUE(j.[value], '$.approver_ecno')
        FROM dbo.workflow_stage ws
        CROSS APPLY OPENJSON(ws.stage_order_json) j
        WHERE ws.workflow_types_id = @wf AND ws.is_active = 'Y'
        ORDER BY CAST(j.[key] AS INT);

    IF @wf IS NOT NULL AND @first IS NOT NULL
    BEGIN
        UPDATE dbo.grn_basic_info
        SET status = 'Pending Approval', workflow_types_id = @wf, current_approver_id = @first
        WHERE grn_basic_sno = @grn;
        INSERT INTO dbo.grn_approval_history (grn_basic_sno, action_type, status_by, comment)
        VALUES (@grn, 'SUBMITTED', @by, N'Submitted for approval to ' + @first);
    END
    ELSE
    BEGIN
        UPDATE dbo.grn_basic_info
        SET status = 'Approved', current_approver_id = NULL, approved_at = GETDATE()
        WHERE grn_basic_sno = @grn;
        INSERT INTO dbo.grn_approval_history (grn_basic_sno, action_type, status_by, comment)
        VALUES (@grn, 'AUTO_APPROVED', @by, N'No GRN approval workflow configured for this department');
    END

    INSERT INTO dbo.grn_history_data (event_type, po_basic_sno, grn_basic_sno, gate_entry_sno, to_status, status_by, remarks)
    SELECT CASE WHEN status = 'Approved' THEN 'GRN Auto Approved' ELSE 'GRN Submitted For Approval' END,
           po_basic_sno, grn_basic_sno, gate_entry_sno, status, @by, NULL
    FROM dbo.grn_basic_info WHERE grn_basic_sno = @grn;

    SELECT grn_basic_sno, status, current_approver_id, workflow_types_id,
           CASE WHEN status = 'Approved' THEN 1 ELSE 0 END AS is_final
    FROM dbo.grn_basic_info WHERE grn_basic_sno = @grn;
END
GO

-- ── approve / reject ────────────────────────────────────────────────────────
-- @jsonInput: { grn_basic_sno, action: 'approve'|'reject', approved_by, comments }
-- Returns result = APPROVED_NEXT | FINAL | REJECTED (+ next_approver).
CREATE OR ALTER PROCEDURE dbo.sp_nt_ApproveGRN
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn INT = JSON_VALUE(@jsonInput, '$.grn_basic_sno'),
            @action VARCHAR(10) = LOWER(JSON_VALUE(@jsonInput, '$.action')),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.approved_by'),
            @comments NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.comments');

    IF @action NOT IN ('approve', 'reject') THROW 53210, 'action must be approve or reject.', 1;

    DECLARE @status VARCHAR(20), @cur VARCHAR(30), @wf INT, @gate INT, @po INT, @creator VARCHAR(30);
    SELECT @status = status, @cur = current_approver_id, @wf = workflow_types_id, @gate = gate_entry_sno,
           @po = po_basic_sno, @creator = created_by
    FROM dbo.grn_basic_info WHERE grn_basic_sno = @grn AND is_active = 'Y';

    IF @status IS NULL THROW 53211, 'GRN not found.', 1;
    IF @status <> 'Pending Approval' THROW 53212, 'This GRN is not awaiting approval.', 1;
    IF @cur IS NULL OR @cur <> @by THROW 53213, 'You are not the current approver of this GRN.', 1;
    IF @action = 'reject' AND (@comments IS NULL OR LTRIM(RTRIM(@comments)) = '')
        THROW 53214, 'Remarks are required to reject.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        IF @action = 'reject'
        BEGIN
            UPDATE dbo.grn_basic_info SET status = 'Rejected', current_approver_id = NULL WHERE grn_basic_sno = @grn;
            UPDATE dbo.grn_item_details SET is_active = 'N' WHERE grn_basic_sno = @grn;
            UPDATE dbo.nt_grn_excess_requests
               SET status = 'Rejected', acted_by = @by, acted_at = GETDATE(), remarks = N'GRN rejected'
             WHERE grn_basic_sno = @grn AND status = 'Pending';
            UPDATE dbo.nt_gate_entry SET status = 'In', updated_by = @by, updated_at = GETDATE()
             WHERE gate_entry_sno = @gate AND status = 'GRN Done';
            INSERT INTO dbo.grn_approval_history (grn_basic_sno, action_type, status_by, comment)
            VALUES (@grn, 'REJECTED', @by, @comments);
            INSERT INTO dbo.grn_history_data (event_type, po_basic_sno, grn_basic_sno, gate_entry_sno, to_status, status_by, remarks)
            VALUES ('GRN Rejected', @po, @grn, @gate, 'Rejected', @by, @comments);
            COMMIT TRANSACTION;
            SELECT 'REJECTED' AS result, @grn AS grn_basic_sno, @creator AS created_by, CAST(NULL AS VARCHAR(30)) AS next_approver;
            RETURN;
        END

        -- next approver after the current one in the workflow's stage list
        DECLARE @next VARCHAR(30) = NULL;
        DECLARE @stages TABLE (seq INT, ecno VARCHAR(30));
        INSERT INTO @stages (seq, ecno)
        SELECT CAST(j.[key] AS INT), JSON_VALUE(j.[value], '$.approver_ecno')
        FROM dbo.workflow_stage ws CROSS APPLY OPENJSON(ws.stage_order_json) j
        WHERE ws.workflow_types_id = @wf AND ws.is_active = 'Y';
        DECLARE @curseq INT = (SELECT MIN(seq) FROM @stages WHERE ecno = @cur);
        SELECT TOP 1 @next = ecno FROM @stages WHERE seq > ISNULL(@curseq, 2147483647) ORDER BY seq;

        INSERT INTO dbo.grn_approval_history (grn_basic_sno, action_type, status_by, comment)
        VALUES (@grn, 'APPROVED', @by, @comments);

        IF @next IS NULL
        BEGIN
            UPDATE dbo.grn_basic_info SET status = 'Approved', current_approver_id = NULL, approved_at = GETDATE()
             WHERE grn_basic_sno = @grn;
            INSERT INTO dbo.grn_history_data (event_type, po_basic_sno, grn_basic_sno, gate_entry_sno, to_status, status_by, remarks)
            VALUES ('GRN Approved', @po, @grn, @gate, 'Approved', @by, @comments);
            COMMIT TRANSACTION;
            SELECT 'FINAL' AS result, @grn AS grn_basic_sno, @creator AS created_by, CAST(NULL AS VARCHAR(30)) AS next_approver;
        END
        ELSE
        BEGIN
            UPDATE dbo.grn_basic_info SET current_approver_id = @next WHERE grn_basic_sno = @grn;
            COMMIT TRANSACTION;
            SELECT 'APPROVED_NEXT' AS result, @grn AS grn_basic_sno, @creator AS created_by, @next AS next_approver;
        END
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ── pending list + history ──────────────────────────────────────────────────
-- @jsonInput: { approver_ecno?, grn_basic_sno? }  - without approver_ecno lists every pending GRN
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNApprovals
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @appr VARCHAR(30) = NULLIF(JSON_VALUE(@jsonInput, '$.approver_ecno'), ''),
            @grn INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.grn_basic_sno') AS INT);

    SELECT b.grn_basic_sno,
           'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
           b.po_basic_sno, b.vendor_sno, CONVERT(VARCHAR(10), b.received_date, 120) AS received_date,
           b.status, b.current_approver_id, b.created_by, CONVERT(VARCHAR(30), b.created_date, 120) AS created_at,
           b.com_sno, b.div_sno, b.brn_sno, b.dept_sno,
           (SELECT COUNT(*) FROM dbo.grn_item_details gi WHERE gi.grn_basic_sno = b.grn_basic_sno AND gi.is_active = 'Y') AS item_count,
           (SELECT ISNULL(SUM(gi.received_qty), 0) FROM dbo.grn_item_details gi WHERE gi.grn_basic_sno = b.grn_basic_sno AND gi.is_active = 'Y') AS total_received_qty
    FROM dbo.grn_basic_info b
    WHERE b.is_active = 'Y'
      AND ((@grn IS NOT NULL AND b.grn_basic_sno = @grn)
        OR (@grn IS NULL AND b.status = 'Pending Approval' AND (@appr IS NULL OR b.current_approver_id = @appr)))
    ORDER BY b.grn_basic_sno DESC;

    SELECT h.grn_basic_sno, h.action_type, h.status_by, h.comment, CONVERT(VARCHAR(30), h.created_at, 120) AS created_at
    FROM dbo.grn_approval_history h
    WHERE (@grn IS NOT NULL AND h.grn_basic_sno = @grn)
    ORDER BY h.history_sno;
END
GO
