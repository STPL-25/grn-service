-- ============================================================
-- ROLLBACK of grn-service sql/83_payment_reverse_file.sql (2026-11-03)
--   cd grn-service && node sql/run_sql.mjs sql/backups/payment_reverse_file_2026-11-03_ROLLBACK.sql
--
-- Restores sp_nt_GetPaymentBatches exactly as it was live on Non_trade_Dev before sql/83, drops the three new procedures, the
-- reverse-file tables and the bank columns, and puts back the plain unique index (one run line per payment, ever).
-- Refuses to run while a payment is in more than one run line (paid again after the bank returned it): the old index cannot hold
-- that. What sql/83 already did to data stays: payments the bank returned are 'Approved' (or paid again), their reversal journals
-- ('PAYMENT_REVERSAL') and the 'Reversed' mark on the old journals stay - they are the books.
-- ============================================================

IF EXISTS (SELECT payment_sno FROM dbo.payment_batch_item GROUP BY payment_sno HAVING COUNT(*) > 1)
    THROW 56399, N'A payment is in more than one run line (paid again after a bank return) - the old one-line-per-payment index cannot be put back.', 1;
GO

DROP PROCEDURE IF EXISTS dbo.sp_nt_ApplyPaymentReverseFile;
DROP PROCEDURE IF EXISTS dbo.sp_nt_GetPaymentBankFailures;
DROP PROCEDURE IF EXISTS dbo.sp_nt_ChangeFailedPaymentMode;
GO

-- ── 9. past runs: same, with the invoice lines ──
-- ── 4. past payment runs ────────────────────────────────────────────────────
-- Past payment runs.  @jsonInput: { batch_sno?, hierarchy?, with_file?, limit? }
-- -> batches (file_content only when with_file and one batch), items of that batch
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentBatches
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bsno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.batch_sno') AS INT),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'),
            @withFile BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.with_file') IN ('1', 'true') THEN 1 ELSE 0 END,
            @limit INT = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.limit') AS INT), 30);

    SELECT TOP (@limit) b.batch_sno, b.batch_no, b.batch_date, b.com_sno, c.com_name, b.div_sno, d.div_name, b.brn_sno, br.brn_name,
           b.fund_plan_amount, b.total_amount, b.item_count, b.status,
           b.file_name, CASE WHEN @withFile = 1 AND @bsno IS NOT NULL THEN b.file_content END AS file_content,
           CAST(CASE WHEN b.file_content IS NULL THEN 0 ELSE 1 END AS BIT) AS has_file,
           b.file_no, b.file_type, b.payment_bank_sno, pb.profile_name AS sender_name, b.sender_bank_name, RIGHT(b.sender_account_no, 4) AS sender_ac_last4,
           b.sender_client_code, b.sender_alert_email,
           b.created_by, CONVERT(VARCHAR(30), b.created_at, 120) AS created_at
    FROM dbo.payment_batch b
    LEFT JOIN dbo.company_master c ON c.com_sno = b.com_sno
    LEFT JOIN dbo.division_master d ON d.div_sno = b.div_sno
    LEFT JOIN dbo.branch_master br ON br.brn_sno = b.brn_sno
    LEFT JOIN dbo.payment_bank_master pb ON pb.payment_bank_sno = b.payment_bank_sno
    WHERE (@bsno IS NULL OR b.batch_sno = @bsno)
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = b.com_sno AND (h.div_sno IS NULL OR h.div_sno = b.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = b.brn_sno)))
    ORDER BY b.batch_sno DESC;

    SELECT i.batch_item_sno, i.batch_sno, i.payment_sno, p.payment_no, i.line_no, i.vendor_sno, i.vendor_name, i.supp_code, i.vendor_email, i.amount, i.mode, i.debit_account,
           i.channel, i.beneficiary_name, i.account_no, i.ifsc, i.bank_name, i.branch_name, i.invoice_nos, i.supplier_invoice_nos, i.msme_label, i.narration, i.gross_amount, i.tds_amount, i.advance_amount, i.note_amount,
           p.com_sno, p.div_sno, p.brn_sno, p.dept_sno
    FROM dbo.payment_batch_item i JOIN dbo.payment_info p ON p.payment_sno = i.payment_sno
    WHERE @bsno IS NOT NULL AND i.batch_sno = @bsno
    ORDER BY i.line_no;

    SELECT l.batch_item_sno, l.batch_sno, l.payment_sno, l.invoice_sno, l.invoice_no, l.supplier_invoice_no, l.invoice_date, l.invoice_amount, l.gst_amount,
           l.payable_total, l.paid_before, l.this_gross, l.tds_amount, l.balance_after, l.awaiting_2b, l.part_no, l.kind
    FROM dbo.payment_batch_item_invoice l WHERE @bsno IS NOT NULL AND l.batch_sno = @bsno
    ORDER BY l.batch_item_sno, l.invoice_sno;
END
GO

DROP TABLE IF EXISTS dbo.payment_bank_event;
DROP TABLE IF EXISTS dbo.payment_reverse_file;
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_payment_batch_item_returned' AND object_id = OBJECT_ID('dbo.payment_batch_item'))
    DROP INDEX IX_payment_batch_item_returned ON dbo.payment_batch_item;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_payment_batch_item_payment' AND object_id = OBJECT_ID('dbo.payment_batch_item') AND has_filter = 1)
    DROP INDEX UX_payment_batch_item_payment ON dbo.payment_batch_item;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_payment_batch_item_payment' AND object_id = OBJECT_ID('dbo.payment_batch_item'))
    CREATE UNIQUE INDEX UX_payment_batch_item_payment ON dbo.payment_batch_item (payment_sno);
GO

IF OBJECT_ID('dbo.CK_payment_batch_item_bank_status', 'C') IS NOT NULL ALTER TABLE dbo.payment_batch_item DROP CONSTRAINT CK_payment_batch_item_bank_status;
IF OBJECT_ID('dbo.CK_payment_batch_item_returned_to_run', 'C') IS NOT NULL ALTER TABLE dbo.payment_batch_item DROP CONSTRAINT CK_payment_batch_item_returned_to_run;
IF OBJECT_ID('dbo.DF_payment_batch_item_returned_to_run', 'D') IS NOT NULL ALTER TABLE dbo.payment_batch_item DROP CONSTRAINT DF_payment_batch_item_returned_to_run;
GO
IF COL_LENGTH('dbo.payment_batch_item', 'bank_status') IS NOT NULL
    ALTER TABLE dbo.payment_batch_item DROP COLUMN bank_status, utr_no, bank_ref_no, bank_debit_date, bank_credit_at, bank_reason_code, bank_reason,
                                                   bank_updated_at, bank_updated_by, reverse_file_sno, reversal_journal_sno, returned_to_run;
GO
