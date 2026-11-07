-- ============================================================
-- ROLLBACK of grn-service sql/96_statutory_agreement_dues.sql  (Non_trade_Dev)
-- Restores sp_nt_GetStatutoryPayables and sp_nt_CancelStatutoryPayable to the definitions saved in this folder, drops the due-date
-- table, its procedures and statutory_payable.cycle_sno, and puts the source_type check back to ('TDS', 'MANUAL').
-- Refuses while any amount from an agreement exists (a posted amount, open or paid, would lose its source).
--   cd grn-service && node sql/run_sql.mjs sql/backups/statutory_agreement_dues_2026-11-07/ROLLBACK.sql
-- Then run the backend-stpl rollback.
-- ============================================================

IF EXISTS (SELECT 1 FROM dbo.statutory_payable WHERE source_type = 'AGREEMENT')
    THROW 57285, N'Amounts from Statutory agreements exist on Statutory Payments. Cancel or pay them and remove them first.', 1;
GO

-- ── 3. the register: + who each open amount will be paid to ────────────────
-- { kind?, status?, hierarchy?, limit? } -> 1: amounts   2: GST held on supplier bills until GSTR-2B
-- pay_to_* (open amounts only): the amount's own payee when it is active, else the kind's default for the company - the same choice
-- the run / the online record makes - so the screen knows which amounts go in a bank file and which are paid online.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStatutoryPayables
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @kind VARCHAR(5) = NULLIF(JSON_VALUE(@jsonInput, '$.kind'), ''), @status VARCHAR(10) = NULLIF(JSON_VALUE(@jsonInput, '$.status'), ''),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'), @limit INT = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.limit') AS INT), 1000);
    BEGIN TRY EXEC dbo.sp_nt_SyncStatutoryTds; END TRY BEGIN CATCH END CATCH   -- a sync problem must never take the list down

    SELECT TOP (@limit) s.stat_sno, s.kind, s.source_type, s.com_sno, c.com_name, s.div_sno, s.brn_sno, s.head_name, s.ref_no, s.period_label, s.party_name,
           s.payment_sno, p.payment_no, s.payee_sno, y.payee_name, y.reference_no AS payee_ref, s.amount, s.due_date,
           CASE WHEN s.status = 'Open' AND s.due_date < CAST(GETDATE() AS DATE) THEN DATEDIFF(DAY, s.due_date, CAST(GETDATE() AS DATE)) END AS days_overdue,
           s.narration, s.status, s.batch_sno, b.batch_no, s.paid_at, s.cancel_reason, s.created_by, CONVERT(VARCHAR(30), s.created_at, 120) AS created_at,
           e.payee_sno AS pay_to_sno, e.payee_name AS pay_to_name, e.pay_via_portal AS pay_to_online,
           e.payment_portal_name AS pay_to_portal_name, e.payment_portal_url AS pay_to_portal_url, e.payment_instructions AS pay_to_instructions,
           b.pay_channel, b.txn_mode, b.txn_id, b.txn_date
    FROM dbo.statutory_payable s
    LEFT JOIN dbo.company_master c ON c.com_sno = s.com_sno
    LEFT JOIN dbo.payment_info p ON p.payment_sno = s.payment_sno
    LEFT JOIN dbo.statutory_payee y ON y.payee_sno = s.payee_sno
    LEFT JOIN dbo.statutory_batch b ON b.batch_sno = s.batch_sno
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
END
GO

-- { stat_sno, reason, cancelled_by, hierarchy? } - an Open amount keyed in by hand. A TDS amount is not cancelled: it is owed.
CREATE OR ALTER PROCEDURE dbo.sp_nt_CancelStatutoryPayable
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.stat_sno') AS INT), @reason NVARCHAR(200) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.reason'))), ''),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');
    IF @reason IS NULL THROW 57220, 'Give the reason.', 1;
    UPDATE s SET status = 'Cancelled', cancel_reason = @reason
    FROM dbo.statutory_payable s
    WHERE s.stat_sno = @id AND s.status = 'Open' AND s.source_type = 'MANUAL'
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = s.com_sno AND (h.div_sno IS NULL OR h.div_sno = s.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = s.brn_sno)));
    IF @@ROWCOUNT = 0 THROW 57221, 'Only an open amount keyed in by hand, inside your access, can be cancelled.', 1;
    SELECT @id AS stat_sno;
END
GO

IF OBJECT_ID('dbo.sp_nt_SkipStatutoryAgreementCycle', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_SkipStatutoryAgreementCycle;
GO
IF OBJECT_ID('dbo.sp_nt_EnterStatutoryAgreementAmount', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_EnterStatutoryAgreementAmount;
GO
IF OBJECT_ID('dbo.sp_nt_SyncStatutoryAgreementDues', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_SyncStatutoryAgreementDues;
GO
IF OBJECT_ID('dbo.statutory_agreement_cycle', 'U') IS NOT NULL DROP TABLE dbo.statutory_agreement_cycle;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_statutory_payable_source')
    ALTER TABLE dbo.statutory_payable DROP CONSTRAINT CK_statutory_payable_source;
GO
IF COL_LENGTH('dbo.statutory_payable', 'cycle_sno') IS NOT NULL
    ALTER TABLE dbo.statutory_payable DROP COLUMN cycle_sno;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_statutory_payable_source_tds_manual')
    ALTER TABLE dbo.statutory_payable ADD CONSTRAINT CK_statutory_payable_source_tds_manual CHECK (source_type IN ('TDS', 'MANUAL'));
GO
