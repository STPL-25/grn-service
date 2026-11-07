-- ============================================================
-- 96_statutory_agreement_dues.sql   (Non_trade_Dev ONLY, re-runnable, NOT APPLIED until the user OKs it)
--
-- Request 2026-11-07: a Statutory agreement is made and approved on the Service Agreement screen (backend-stpl sql/157); after
-- approval every due date of it shows here, on Statutory Payments, and is paid like any other statutory amount.
--
--   statutory_agreement_cycle   one row per due date of an approved Statutory agreement (unique per agreement + cadence slot)
--                               Waiting = no amount yet (Unfixed) -> Posted = became an Open statutory_payable -> paid by the run
--                               Skipped = nothing to pay this time (with the reason)
--   statutory_payable           + cycle_sno; source_type may now be 'AGREEMENT'
--   sp_nt_SyncStatutoryAgreementDues   adds the due dates that have come into view (notify_days_before ahead of the due date),
--                               only dates on / after the agreement was first approved and inside its term; a Fixed agreement's
--                               dues are posted straight away with its amount. Runs every time the register is read.
--   sp_nt_EnterStatutoryAgreementAmount   Unfixed: the amount for one due date -> an Open amount (no second approval: user's choice)
--   sp_nt_SkipStatutoryAgreementCycle     a waiting due date that has nothing to pay, with the reason
--   sp_nt_CancelStatutoryPayable  an Open amount from an agreement can be withdrawn too: Unfixed goes back to waiting for an
--                               amount, Fixed is marked skipped with the reason
--   sp_nt_GetStatutoryPayables  + agreement no on each amount, + 3rd result: the due dates waiting for an amount
--
-- Runs, bank files and online payments are unchanged: once posted, an agreement amount is an ordinary Open amount.
-- Needs sql/73 + sql/82 here and backend-stpl sql/157. Error numbers 57270-57285.
-- Apply: cd grn-service && node sql/run_sql.mjs sql/96_statutory_agreement_dues.sql
-- Rollback: sql/backups/statutory_agreement_dues_2026-11-07/ROLLBACK.sql
-- ============================================================

IF OBJECT_ID('dbo.statutory_payable', 'U') IS NULL OR OBJECT_ID('dbo.sp_nt_RecordStatutoryOnlinePayment', 'P') IS NULL
    THROW 57270, N'Run sql/73 and sql/82 first: Statutory Payments is not set up.', 1;
IF OBJECT_ID('dbo.service_agreement_statutory_due', 'U') IS NULL
    THROW 57270, N'Run backend-stpl sql/157 first: Statutory agreements are not set up.', 1;
GO

-- ── 1. statutory_payable: amounts from an agreement ─────────────────────────
IF COL_LENGTH('dbo.statutory_payable', 'cycle_sno') IS NULL
    ALTER TABLE dbo.statutory_payable ADD cycle_sno INT NULL;
GO
-- sql/73 made an unnamed CHECK (source_type IN ('TDS', 'MANUAL')); swap it for a named one that also allows AGREEMENT
DECLARE @old_ck SYSNAME = (SELECT TOP 1 name FROM sys.check_constraints
                           WHERE parent_object_id = OBJECT_ID('dbo.statutory_payable') AND name <> 'CK_statutory_payable_source'
                             AND definition LIKE '%source_type%');
IF @old_ck IS NOT NULL
BEGIN
    DECLARE @drop NVARCHAR(400) = N'ALTER TABLE dbo.statutory_payable DROP CONSTRAINT ' + QUOTENAME(@old_ck) + N';';
    EXEC (@drop);
END
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_statutory_payable_source')
    ALTER TABLE dbo.statutory_payable ADD CONSTRAINT CK_statutory_payable_source CHECK (source_type IN ('TDS', 'MANUAL', 'AGREEMENT'));
GO

-- ── 2. the due dates ────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.statutory_agreement_cycle', 'U') IS NULL
CREATE TABLE dbo.statutory_agreement_cycle (
    cycle_sno     INT IDENTITY(1,1) PRIMARY KEY,
    agreement_sno INT           NOT NULL,
    due_date      DATE          NOT NULL,
    period_label  NVARCHAR(30)  NULL,
    status        VARCHAR(10)   NOT NULL DEFAULT 'Waiting'
                                CONSTRAINT CK_statutory_agreement_cycle_status CHECK (status IN ('Waiting', 'Posted', 'Skipped')),
    amount        DECIMAL(18,2) NULL,          -- what was posted (Fixed: the agreement amount; Unfixed: what was entered)
    stat_sno      INT           NULL,          -- the statutory_payable it became
    skip_reason   NVARCHAR(200) NULL,
    entered_by    VARCHAR(30)   NULL,
    entered_at    DATETIME      NULL,
    created_at    DATETIME      NOT NULL DEFAULT GETDATE(),
    CONSTRAINT UQ_statutory_agreement_cycle UNIQUE (agreement_sno, due_date)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_statutory_agreement_cycle_status')
    CREATE INDEX IX_statutory_agreement_cycle_status ON dbo.statutory_agreement_cycle (status, agreement_sno);
GO

-- ── 3. add the due dates that have come into view ───────────────────────────
-- A due date shows notify_days_before days ahead (0 = on the day). Only dates inside the agreement term and on / after the day it was
-- first approved: the months before that were paid outside the system. Each cadence slot (a month for Monthly, three for Quarterly,
-- N days for a day cadence, counted from the term start) gets at most one due date, so changing the due day never doubles a month.
-- Same date rule as the PO sweep: day D of the month (clamped to the month end), every interval months from the start month.
CREATE OR ALTER PROCEDURE dbo.sp_nt_SyncStatutoryAgreementDues
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);

    BEGIN TRANSACTION;
    DECLARE @lk INT;
    EXEC @lk = sp_getapplock @Resource = 'statutory_agreement_sync', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 5000;
    IF @lk < 0 BEGIN ROLLBACK TRANSACTION; RETURN; END

    ;WITH ag AS (
        SELECT sa.agreement_sno, sa.period_start_date AS ps, sa.period_end_date AS pe, sa.po_generation_day AS dd,
               ISNULL(sa.notify_days_before, 0) AS nb, rc.interval_unit AS iu, rc.interval_value AS iv,
               DATEFROMPARTS(YEAR(sa.period_start_date), MONTH(sa.period_start_date), 1) AS m0,
               (SELECT CAST(MIN(v.decided_at) AS DATE) FROM dbo.service_agreement_version v
                WHERE v.agreement_sno = sa.agreement_sno AND v.outcome = 'APPROVED') AS first_ok
        FROM dbo.service_agreement sa
        JOIN dbo.service_agreement_statutory_due d ON d.agreement_sno = sa.agreement_sno AND d.is_active = 'Y'
        JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
        JOIN dbo.service_type_master st ON st.service_type_sno = sm.service_type_sno AND st.service_type_code = 'STATUTORY'
        JOIN dbo.recurrence_cadence_master rc ON rc.recurrence_cadence_sno = sa.recurrence_cadence_sno
        WHERE sa.is_active = 'Y' AND sa.status IN ('A', 'X') AND rc.interval_value > 0
    ),
    n AS (SELECT TOP (2400) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS k FROM sys.all_columns a CROSS JOIN sys.all_columns b),
    slot AS (
        SELECT ag.agreement_sno, ag.ps, ag.pe, ag.nb, ag.first_ok, ag.iu, ag.dd,
               CASE WHEN ag.iu = 'DAY' THEN DATEADD(DAY, n.k * ag.iv, ag.ps) ELSE DATEADD(MONTH, n.k * ag.iv, ag.m0) END AS slot_start,
               CASE WHEN ag.iu = 'DAY' THEN DATEADD(DAY, (n.k + 1) * ag.iv - 1, ag.ps) ELSE DATEADD(DAY, -1, DATEADD(MONTH, (n.k + 1) * ag.iv, ag.m0)) END AS slot_end,
               CASE WHEN ag.iu = 'DAY' THEN DATEADD(DAY, n.k * ag.iv, ag.ps)
                    WHEN ag.dd IS NULL THEN DATEADD(MONTH, n.k * ag.iv, ag.ps)
                    ELSE DATEADD(DAY, (CASE WHEN ag.dd > DAY(EOMONTH(DATEADD(MONTH, n.k * ag.iv, ag.m0))) THEN DAY(EOMONTH(DATEADD(MONTH, n.k * ag.iv, ag.m0))) ELSE ag.dd END) - 1,
                                 DATEADD(MONTH, n.k * ag.iv, ag.m0)) END AS due_date
        FROM ag CROSS JOIN n
        WHERE ag.first_ok IS NOT NULL
          AND ((ag.iu = 'DAY' AND n.k * ag.iv <= DATEDIFF(DAY, ag.ps, ag.pe)) OR (ag.iu = 'MONTH' AND n.k * ag.iv <= DATEDIFF(MONTH, ag.ps, ag.pe)))
    )
    INSERT INTO dbo.statutory_agreement_cycle (agreement_sno, due_date, period_label)
    SELECT s.agreement_sno, s.due_date,
           CASE WHEN s.iu = 'DAY' THEN FORMAT(s.due_date, 'dd MMM yyyy', 'en-IN') ELSE FORMAT(s.due_date, 'MMM yyyy', 'en-IN') END
    FROM slot s
    WHERE s.due_date BETWEEN s.ps AND s.pe
      AND s.due_date >= s.first_ok
      AND DATEADD(DAY, -s.nb, s.due_date) <= @today
      AND NOT EXISTS (SELECT 1 FROM dbo.statutory_agreement_cycle x WITH (UPDLOCK, HOLDLOCK)
                      WHERE x.agreement_sno = s.agreement_sno AND x.due_date BETWEEN s.slot_start AND s.slot_end);

    -- a Fixed agreement's due needs no typing: post it with the agreement amount
    DECLARE @posted TABLE (stat_sno INT, cycle_sno INT, amount DECIMAL(18,2));
    INSERT INTO dbo.statutory_payable (kind, source_type, com_sno, div_sno, brn_sno, dept_sno, head_name, ref_no, period_label,
                                       payee_sno, amount, due_date, narration, created_by, cycle_sno)
    OUTPUT inserted.stat_sno, inserted.cycle_sno, inserted.amount INTO @posted
    SELECT d.kind, 'AGREEMENT', sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno, LEFT(sm.service_name, 100), d.reference_no, c.period_label,
           d.payee_sno, ROUND(sa.rate_amount * sa.qty, 2), c.due_date, LEFT(N'Agreement ' + sa.agreement_no, 200), 'system', c.cycle_sno
    FROM dbo.statutory_agreement_cycle c
    JOIN dbo.service_agreement sa ON sa.agreement_sno = c.agreement_sno
    JOIN dbo.service_agreement_statutory_due d ON d.agreement_sno = c.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    WHERE c.status = 'Waiting' AND d.amount_type = 'FIXED' AND d.is_active = 'Y' AND sa.is_active = 'Y' AND sa.status IN ('A', 'X')
      AND ROUND(sa.rate_amount * sa.qty, 2) > 0;

    UPDATE c SET status = 'Posted', stat_sno = p.stat_sno, amount = p.amount, entered_by = 'system', entered_at = GETDATE()
    FROM dbo.statutory_agreement_cycle c JOIN @posted p ON p.cycle_sno = c.cycle_sno;

    COMMIT TRANSACTION;
END;
GO

-- ── 4. Unfixed: the amount for one due date ─────────────────────────────────
-- { cycle_sno, amount, ref_no?, narration?, entered_by, hierarchy? } -> stat_sno, cycle_sno
CREATE OR ALTER PROCEDURE dbo.sp_nt_EnterStatutoryAgreementAmount
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @cycle INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.cycle_sno') AS INT),
            @amount DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.amount') AS DECIMAL(18,2)),
            @ref NVARCHAR(200) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ref_no'))), ''),
            @narr NVARCHAR(400) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.narration'))), ''),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.entered_by'),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');
    IF @by IS NULL THROW 57271, 'entered_by is required.', 1;
    IF @cycle IS NULL THROW 57272, 'Choose the due date to enter the amount for.', 1;
    IF @amount IS NULL OR @amount <= 0 THROW 57273, 'Enter an amount above zero.', 1;
    IF LEN(@ref) > 40 THROW 57274, 'The reference / challan number can be at most 40 characters.', 1;
    IF LEN(@narr) > 200 THROW 57274, 'The note can be at most 200 characters.', 1;

    BEGIN TRANSACTION;
    DECLARE @status VARCHAR(10), @ag INT, @com INT, @div INT, @brn INT;
    SELECT @status = c.status, @ag = c.agreement_sno, @com = sa.com_sno, @div = sa.div_sno, @brn = sa.brn_sno
    FROM dbo.statutory_agreement_cycle c WITH (UPDLOCK, HOLDLOCK)
    JOIN dbo.service_agreement sa ON sa.agreement_sno = c.agreement_sno AND sa.is_active = 'Y'
    JOIN dbo.service_agreement_statutory_due d ON d.agreement_sno = c.agreement_sno AND d.is_active = 'Y'
    WHERE c.cycle_sno = @cycle;
    IF @status IS NULL THROW 57275, 'That due date was not found, or its agreement was switched off.', 1;
    IF @hier IS NOT NULL AND NOT EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                         WHERE h.com_sno = @com AND (h.div_sno IS NULL OR h.div_sno = @div) AND (h.brn_sno IS NULL OR h.brn_sno = @brn))
        THROW 57276, 'You do not have access to that company / division / branch.', 1;
    IF @status <> 'Waiting' THROW 57277, 'The amount for that due date was already entered (or it was skipped) - refresh the list.', 1;

    DECLARE @new TABLE (stat_sno INT);
    INSERT INTO dbo.statutory_payable (kind, source_type, com_sno, div_sno, brn_sno, dept_sno, head_name, ref_no, period_label,
                                       payee_sno, amount, due_date, narration, created_by, cycle_sno)
    OUTPUT inserted.stat_sno INTO @new
    SELECT d.kind, 'AGREEMENT', sa.com_sno, sa.div_sno, sa.brn_sno, sa.dept_sno, LEFT(sm.service_name, 100), ISNULL(@ref, d.reference_no), c.period_label,
           d.payee_sno, @amount, c.due_date, ISNULL(@narr, LEFT(N'Agreement ' + sa.agreement_no, 200)), @by, c.cycle_sno
    FROM dbo.statutory_agreement_cycle c
    JOIN dbo.service_agreement sa ON sa.agreement_sno = c.agreement_sno
    JOIN dbo.service_agreement_statutory_due d ON d.agreement_sno = c.agreement_sno
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    WHERE c.cycle_sno = @cycle;

    DECLARE @stat INT = (SELECT TOP 1 stat_sno FROM @new);
    UPDATE dbo.statutory_agreement_cycle SET status = 'Posted', stat_sno = @stat, amount = @amount, entered_by = @by, entered_at = GETDATE(), skip_reason = NULL
    WHERE cycle_sno = @cycle;
    COMMIT TRANSACTION;

    SELECT @stat AS stat_sno, @cycle AS cycle_sno;
END;
GO

-- ── 5. a due date with nothing to pay ───────────────────────────────────────
-- { cycle_sno, reason, skipped_by, hierarchy? }
CREATE OR ALTER PROCEDURE dbo.sp_nt_SkipStatutoryAgreementCycle
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @cycle INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.cycle_sno') AS INT),
            @reason NVARCHAR(400) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.reason'))), ''),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.skipped_by'),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');
    IF @by IS NULL THROW 57278, 'skipped_by is required.', 1;
    IF @reason IS NULL THROW 57279, 'Give the reason there is nothing to pay.', 1;
    IF LEN(@reason) > 200 THROW 57279, 'The reason can be at most 200 characters.', 1;
    UPDATE c SET status = 'Skipped', skip_reason = @reason, entered_by = @by, entered_at = GETDATE()
    FROM dbo.statutory_agreement_cycle c
    JOIN dbo.service_agreement sa ON sa.agreement_sno = c.agreement_sno
    WHERE c.cycle_sno = @cycle AND c.status = 'Waiting'
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = sa.com_sno AND (h.div_sno IS NULL OR h.div_sno = sa.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = sa.brn_sno)));
    IF @@ROWCOUNT = 0 THROW 57280, 'Only a due date still waiting for its amount, inside your access, can be skipped.', 1;
    SELECT @cycle AS cycle_sno;
END;
GO

-- ── 6. withdraw an open amount: by hand, or from an agreement ───────────────
-- { stat_sno, reason, cancelled_by?, hierarchy? }. A TDS amount is not cancelled: it is owed.
-- From an agreement: Unfixed goes back to waiting for its amount (so the right one can be entered), Fixed is marked skipped.
CREATE OR ALTER PROCEDURE dbo.sp_nt_CancelStatutoryPayable
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.stat_sno') AS INT), @reason NVARCHAR(200) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.reason'))), ''),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');
    IF @reason IS NULL THROW 57220, 'Give the reason.', 1;

    BEGIN TRANSACTION;
    DECLARE @gone TABLE (cycle_sno INT NULL);
    UPDATE s SET status = 'Cancelled', cancel_reason = @reason
    OUTPUT inserted.cycle_sno INTO @gone
    FROM dbo.statutory_payable s
    WHERE s.stat_sno = @id AND s.status = 'Open' AND s.source_type IN ('MANUAL', 'AGREEMENT')
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = s.com_sno AND (h.div_sno IS NULL OR h.div_sno = s.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = s.brn_sno)));
    IF @@ROWCOUNT = 0 THROW 57221, 'Only an open amount keyed in by hand or from an agreement, inside your access, can be cancelled.', 1;

    UPDATE c
    SET status = CASE WHEN d.amount_type = 'UNFIXED' THEN 'Waiting' ELSE 'Skipped' END,
        stat_sno = CASE WHEN d.amount_type = 'UNFIXED' THEN NULL ELSE c.stat_sno END,
        amount = CASE WHEN d.amount_type = 'UNFIXED' THEN NULL ELSE c.amount END,
        skip_reason = CASE WHEN d.amount_type = 'UNFIXED' THEN NULL ELSE @reason END,
        entered_by = CASE WHEN d.amount_type = 'UNFIXED' THEN NULL ELSE c.entered_by END,
        entered_at = CASE WHEN d.amount_type = 'UNFIXED' THEN NULL ELSE c.entered_at END
    FROM dbo.statutory_agreement_cycle c
    JOIN @gone g ON g.cycle_sno = c.cycle_sno
    LEFT JOIN dbo.service_agreement_statutory_due d ON d.agreement_sno = c.agreement_sno
    WHERE c.stat_sno = @id;
    COMMIT TRANSACTION;

    SELECT @id AS stat_sno;
END;
GO

-- ── 7. the register: + agreement no, + the due dates waiting for an amount ──
-- { kind?, status?, hierarchy?, limit? } -> 1: amounts   2: GST held on supplier bills until GSTR-2B   3: agreement due dates waiting for an amount
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStatutoryPayables
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @kind VARCHAR(5) = NULLIF(JSON_VALUE(@jsonInput, '$.kind'), ''), @status VARCHAR(10) = NULLIF(JSON_VALUE(@jsonInput, '$.status'), ''),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'), @limit INT = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.limit') AS INT), 1000);
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    BEGIN TRY EXEC dbo.sp_nt_SyncStatutoryTds; END TRY BEGIN CATCH END CATCH              -- a sync problem must never take the list down
    BEGIN TRY EXEC dbo.sp_nt_SyncStatutoryAgreementDues; END TRY BEGIN CATCH IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; END CATCH

    SELECT TOP (@limit) s.stat_sno, s.kind, s.source_type, s.com_sno, c.com_name, s.div_sno, s.brn_sno, s.head_name, s.ref_no, s.period_label, s.party_name,
           s.payment_sno, p.payment_no, s.payee_sno, y.payee_name, y.reference_no AS payee_ref, s.amount, s.due_date,
           CASE WHEN s.status = 'Open' AND s.due_date < @today THEN DATEDIFF(DAY, s.due_date, @today) END AS days_overdue,
           s.narration, s.status, s.batch_sno, b.batch_no, s.paid_at, s.cancel_reason, s.created_by, CONVERT(VARCHAR(30), s.created_at, 120) AS created_at,
           e.payee_sno AS pay_to_sno, e.payee_name AS pay_to_name, e.pay_via_portal AS pay_to_online,
           e.payment_portal_name AS pay_to_portal_name, e.payment_portal_url AS pay_to_portal_url, e.payment_instructions AS pay_to_instructions,
           b.pay_channel, b.txn_mode, b.txn_id, b.txn_date,
           s.cycle_sno, sac.agreement_sno, sag.agreement_no, sad.amount_type AS agreement_amount_type
    FROM dbo.statutory_payable s
    LEFT JOIN dbo.company_master c ON c.com_sno = s.com_sno
    LEFT JOIN dbo.payment_info p ON p.payment_sno = s.payment_sno
    LEFT JOIN dbo.statutory_payee y ON y.payee_sno = s.payee_sno
    LEFT JOIN dbo.statutory_batch b ON b.batch_sno = s.batch_sno
    LEFT JOIN dbo.statutory_agreement_cycle sac ON sac.cycle_sno = s.cycle_sno
    LEFT JOIN dbo.service_agreement sag ON sag.agreement_sno = sac.agreement_sno
    LEFT JOIN dbo.service_agreement_statutory_due sad ON sad.agreement_sno = sac.agreement_sno
    OUTER APPLY (SELECT TOP 1 z.payee_sno, z.payee_name, z.pay_via_portal, z.payment_portal_name, z.payment_portal_url, z.payment_instructions
                 FROM dbo.statutory_payee z
                 WHERE s.status = 'Open' AND z.is_active = 'Y'
                   AND (z.payee_sno = s.payee_sno OR (z.kind = s.kind AND (z.com_sno = s.com_sno OR z.com_sno IS NULL)))
                 ORDER BY CASE WHEN z.payee_sno = s.payee_sno THEN 0 ELSE 1 END, CASE WHEN z.com_sno = s.com_sno THEN 0 ELSE 1 END,
                          CASE WHEN z.is_default = 'Y' THEN 0 ELSE 1 END, z.payee_sno) e
    WHERE (@kind IS NULL OR s.kind = @kind) AND (@status IS NULL OR s.status = @status) AND s.status <> 'Cancelled'
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = s.com_sno AND (h.div_sno IS NULL OR h.div_sno = s.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = s.brn_sno)))
    ORDER BY CASE WHEN s.status = 'Open' THEN 0 ELSE 1 END, CASE WHEN s.due_date IS NULL THEN 1 ELSE 0 END, s.due_date, s.stat_sno DESC;

    SELECT i.invoice_sno, i.invoice_no, i.vendor_invoice_no AS supplier_invoice_no, k.company_name AS vendor_name,
           bp.gst_part AS gst_amount
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    CROSS APPLY dbo.fn_nt_BillPayable(iad.invoice_alloc_sno) bp
    WHERE @kind IN ('GST') AND iad.is_active = 'Y' AND bp.outstanding > 0.01 AND bp.on_hold_2b = 1 AND bp.taxable_known = 1 AND bp.gst_part > 0
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = i.com_sno AND (h.div_sno IS NULL OR h.div_sno = i.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = i.brn_sno)))
    ORDER BY i.invoice_date, i.invoice_sno;

    -- sql/96: agreement due dates still waiting for their amount (Unfixed). Shown with the open amounts; "Paid" lists do not need them.
    SELECT TOP (@limit) cy.cycle_sno, cy.agreement_sno, sa.agreement_no, d.kind, LEFT(sm.service_name, 100) AS head_name, d.reference_no AS ref_no,
           cy.period_label, cy.due_date,
           CASE WHEN cy.due_date < @today THEN DATEDIFF(DAY, cy.due_date, @today) END AS days_overdue,
           ROUND(sa.rate_amount * sa.qty, 2) AS expected_amount,
           sa.com_sno, cm.com_name, sa.div_sno, sa.brn_sno, sa.dept_sno,
           e.payee_sno AS pay_to_sno, e.payee_name AS pay_to_name, e.pay_via_portal AS pay_to_online
    FROM dbo.statutory_agreement_cycle cy
    JOIN dbo.service_agreement sa ON sa.agreement_sno = cy.agreement_sno AND sa.is_active = 'Y'
    JOIN dbo.service_agreement_statutory_due d ON d.agreement_sno = cy.agreement_sno AND d.is_active = 'Y'
    JOIN dbo.service_master sm ON sm.service_sno = sa.service_sno
    LEFT JOIN dbo.company_master cm ON cm.com_sno = sa.com_sno
    OUTER APPLY (SELECT TOP 1 z.payee_sno, z.payee_name, z.pay_via_portal
                 FROM dbo.statutory_payee z
                 WHERE z.is_active = 'Y' AND (z.payee_sno = d.payee_sno OR (z.kind = d.kind AND (z.com_sno = sa.com_sno OR z.com_sno IS NULL)))
                 ORDER BY CASE WHEN z.payee_sno = d.payee_sno THEN 0 ELSE 1 END, CASE WHEN z.com_sno = sa.com_sno THEN 0 ELSE 1 END,
                          CASE WHEN z.is_default = 'Y' THEN 0 ELSE 1 END, z.payee_sno) e
    WHERE cy.status = 'Waiting' AND (@kind IS NULL OR d.kind = @kind) AND (@status IS NULL OR @status = 'Open')
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = sa.com_sno AND (h.div_sno IS NULL OR h.div_sno = sa.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = sa.brn_sno)))
    ORDER BY cy.due_date, cy.cycle_sno;
END;
GO
