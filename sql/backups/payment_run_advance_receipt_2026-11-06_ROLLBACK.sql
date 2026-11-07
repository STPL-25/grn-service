-- Rollback for sql/90_payment_run_advance_receipt.sql: dbo.sp_nt_GetPaymentEntries exactly as it was live on Non_trade_Dev on 2026-11-06.
--   cd grn-service && node sql/run_sql.mjs sql/backups/payment_run_advance_receipt_2026-11-06_ROLLBACK.sql

-- ── 7. entries: the "awaiting me" list also holds payments the caller is an overdue ALTERNATE for, and a payment
--      stays visible to everyone who handled it ───────────────────────────────────────────────────────────────────────
-- Same as sql/65 (see its header for the views) except the two predicates marked (66).
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentEntries
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @view VARCHAR(10) = LOWER(ISNULL(NULLIF(JSON_VALUE(@jsonInput, '$.view'), ''), 'run')),
            @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT),
            @vendor INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @comf INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT),
            @status VARCHAR(20) = NULLIF(JSON_VALUE(@jsonInput, '$.status'), ''),
            @ecno VARCHAR(30) = NULLIF(JSON_VALUE(@jsonInput, '$.ecno'), ''),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'),
            @limit INT = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.limit') AS INT), 300),
            @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @withLines BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.with_lines') IN ('0', 'false') THEN 0
                                  WHEN JSON_VALUE(@jsonInput, '$.with_lines') IN ('1', 'true') THEN 1
                                  WHEN @pay IS NOT NULL OR @view = 'run' THEN 1 ELSE 0 END,
            @msmeDays INT = ISNULL((SELECT TRY_CAST(setting_value AS INT) FROM dbo.nt_payment_run_setting WHERE setting_key = 'MSME_LIMIT_DAYS'), 45),
            @creditDays INT = ISNULL((SELECT TRY_CAST(setting_value AS INT) FROM dbo.nt_payment_run_setting WHERE setting_key = 'DEFAULT_CREDIT_DAYS'), 30);

    -- approved POs with an advance become advance payments waiting in the run (idempotent; never blocks the list)
    IF @view = 'run' AND @pay IS NULL
    BEGIN TRY
        EXEC dbo.sp_nt_SyncPoAdvancePayments;
    END TRY
    BEGIN CATCH
    END CATCH

    -- which payments
    SELECT TOP (@limit) pi.payment_sno
    INTO #p
    FROM dbo.payment_info pi
    WHERE pi.is_active = 'Y'
      AND ( (@pay IS NOT NULL AND pi.payment_sno = @pay)
         OR (@pay IS NULL AND ( (@view = 'run'  AND pi.status = 'Approved' AND pi.batch_sno IS NULL)
                             OR (@view = 'mine' AND pi.status = 'Pending Approval'
                                 AND ( pi.current_approver_id = @ecno
                                    OR EXISTS (SELECT 1 FROM dbo.approval_instance a2 CROSS APPLY OPENJSON(a2.stages_json) st      -- (66) an overdue alternate
                                               WHERE a2.entity_type = 'Payment' AND a2.entity_ref_id = pi.payment_sno AND a2.status = 'P'
                                                 AND st.[key] = CAST(a2.current_seq AS NVARCHAR(10))
                                                 AND EXISTS (SELECT 1 FROM OPENJSON(st.value, '$.alternates') al WHERE al.value COLLATE DATABASE_DEFAULT = @ecno)
                                                 AND DATEDIFF(MINUTE, a2.current_since, GETDATE()) >= ISNULL(TRY_CAST(JSON_VALUE(st.value, '$.escalation_hours') AS INT), 24) * 60)))
                             OR  @view = 'all') ) )
      AND (@status IS NULL OR pi.status = @status)
      AND (@vendor IS NULL OR pi.vendor_sno = @vendor)
      AND (@comf IS NULL OR pi.com_sno = @comf)
      AND (@view = 'mine' OR @hier IS NULL
           OR (@view <> 'run' AND (pi.created_by = @ecno OR pi.current_approver_id = @ecno
                                   OR EXISTS (SELECT 1 FROM dbo.payment_approval_history h WHERE h.payment_sno = pi.payment_sno AND h.status_by = @ecno)))   -- (66) everyone who handled it
           OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                      WHERE h.com_sno = pi.com_sno AND (h.div_sno IS NULL OR h.div_sno = pi.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = pi.brn_sno)))
    ORDER BY pi.payment_sno DESC;

    -- supplier's MSME class
    SELECT pi.payment_sno,
           CASE WHEN ISNULL(k.is_msme_avail, 'N') <> 'Y' AND NULLIF(LTRIM(RTRIM(k.msme_type)), '') IS NULL THEN NULL
                WHEN UPPER(LTRIM(RTRIM(k.msme_type))) = 'MICRO'  THEN 'MICRO'
                WHEN UPPER(LTRIM(RTRIM(k.msme_type))) = 'SMALL'  THEN 'SMALL'
                WHEN UPPER(LTRIM(RTRIM(k.msme_type))) = 'MEDIUM' THEN 'MEDIUM'
                ELSE 'MSME' END AS msme_class
    INTO #v
    FROM #p JOIN dbo.payment_info pi ON pi.payment_sno = #p.payment_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pi.vendor_sno;

    -- lines, with the due date of each
    SELECT l.payment_sno, l.invoice_sno, l.invoice_no, l.supplier_invoice_no, l.po_no, l.invoice_date, l.amount, l.bucket_type,
           l.gate_entry_nos, l.gate_entry_date, l.grn_nos, l.grn_date, l.received_date,
           COALESCE(l.received_date, l.invoice_date) AS start_date,
           CAST(CASE WHEN v.msme_class IN ('MICRO', 'SMALL', 'MSME') AND COALESCE(l.received_date, l.invoice_date) IS NOT NULL
                     THEN DATEADD(DAY, @msmeDays, COALESCE(l.received_date, l.invoice_date)) END AS DATE) AS statutory_due,
           CAST(CASE WHEN l.agreed_due_date >= ISNULL(l.invoice_date, '19000101') THEN l.agreed_due_date END AS DATE) AS agreed_due
    INTO #l0
    FROM #p JOIN dbo.fn_nt_PaymentLines(@pay) l ON l.payment_sno = #p.payment_sno
    JOIN #v v ON v.payment_sno = l.payment_sno;

    SELECT x.*,
           CAST(CASE WHEN x.statutory_due IS NOT NULL AND x.agreed_due IS NOT NULL THEN (CASE WHEN x.agreed_due < x.statutory_due THEN x.agreed_due ELSE x.statutory_due END)
                     WHEN x.statutory_due IS NOT NULL THEN x.statutory_due
                     WHEN x.agreed_due IS NOT NULL THEN x.agreed_due
                     WHEN x.start_date IS NOT NULL THEN DATEADD(DAY, @creditDays, x.start_date) END AS DATE) AS due_date
    INTO #l
    FROM #l0 x;

    -- one row per payment
    SELECT pi.payment_sno, pi.payment_no, ISNULL(pi.payment_type, 'BILL') AS payment_type, pi.po_basic_sno, pi.adv_stage_no, pi.vendor_sno, k.company_name AS vendor_name, k.supp_code, k.email AS vendor_email,
           pi.mode, pi.bank_account AS debit_account, pi.reference_no, pi.remarks, pi.payment_date,
           pi.status, pi.current_approver_id, pi.workflow_types_id, pi.created_by, pi.created_date AS created_at, pi.approved_at, pi.processed_at,
           pi.batch_sno, b.batch_no,
           pi.gross_amount, pi.tds_amount, pi.advance_adjusted, pi.note_adjusted, ISNULL(pi.net_paid, pi.amount) AS net_paid, pi.amount,
           pi.com_sno, pi.div_sno, pi.brn_sno, pi.dept_sno, c.com_name,
           v.msme_class,
           CASE v.msme_class WHEN 'MICRO' THEN 'Micro' WHEN 'SMALL' THEN 'Small' WHEN 'MEDIUM' THEN 'Medium' WHEN 'MSME' THEN 'MSME' END AS msme_label,
           CASE v.msme_class WHEN 'MICRO' THEN 1 WHEN 'SMALL' THEN 2 WHEN 'MEDIUM' THEN 3 WHEN 'MSME' THEN 3 ELSE 4 END AS msme_tier,
           k.msme_no,
           CAST(CASE WHEN v.msme_class IN ('MICRO', 'SMALL', 'MSME') THEN 1 ELSE 0 END AS BIT) AS is_statutory,
           CAST(CASE WHEN k.pay_via_portal = 'Y' THEN 1 ELSE 0 END AS BIT) AS pay_via_portal, k.payment_portal_name, k.payment_portal_url,
           bk.ac_holder_name, CAST(bk.ac_number AS VARCHAR(30)) AS ac_number, bk.ifsc, bk.bank_name, bk.bank_branch_name,
           ch.channel,
           CAST(CASE WHEN ch.channel <> 'BANK' THEN 1
                     WHEN bk.ac_number IS NOT NULL AND NULLIF(LTRIM(RTRIM(bk.ifsc)), '') IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS bank_ready,
           agg.invoice_count, agg.invoice_nos, agg.supplier_invoice_nos, COALESCE(agg.po_nos, apo.po_df_no) AS po_nos, agg.gate_entry_nos, agg.grn_nos,
           agg.first_gate_entry_date, agg.first_grn_date, agg.accepted_date, COALESCE(agg.due_date, pi.adv_due_date) AS due_date, agg.statutory_due_date,
           DATEDIFF(DAY, @today, COALESCE(agg.due_date, pi.adv_due_date)) AS days_to_due,
           CAST(CASE WHEN COALESCE(agg.due_date, pi.adv_due_date) < @today THEN 1 ELSE 0 END AS BIT) AS is_overdue
    INTO #e
    FROM #p
    JOIN dbo.payment_info pi ON pi.payment_sno = #p.payment_sno
    JOIN #v v ON v.payment_sno = pi.payment_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pi.vendor_sno
    LEFT JOIN dbo.payment_batch b ON b.batch_sno = pi.batch_sno
    LEFT JOIN dbo.company_master c ON c.com_sno = pi.com_sno
    LEFT JOIN dbo.po_request_info apo ON apo.po_basic_sno = pi.po_basic_sno AND pi.payment_type = 'ADVANCE'
    OUTER APPLY (SELECT TOP 1 x.ac_holder_name, x.ac_number, x.ifsc, x.bank_name, x.bank_branch_name
                 FROM dbo.kyc_bank_info x
                 WHERE x.kyc_basic_info_sno = pi.vendor_sno AND ISNULL(x.is_active, 'Y') = 'Y'
                 ORDER BY CASE WHEN x.is_primary = 'Y' THEN 0 ELSE 1 END, x.kyc_address_sno DESC) bk
    CROSS APPLY (SELECT CASE WHEN ISNULL(pi.net_paid, pi.amount) = 0 THEN 'ADJUSTMENT'
                             WHEN k.pay_via_portal = 'Y' THEN 'PORTAL'
                             WHEN UPPER(pi.mode) IN ('CHEQUE', 'CASH', 'DD') THEN 'MANUAL'
                             ELSE 'BANK' END AS channel) ch
    OUTER APPLY (
        SELECT COUNT(*) AS invoice_count,
               STRING_AGG(l.invoice_no, ', ') WITHIN GROUP (ORDER BY l.invoice_sno) AS invoice_nos,
               STRING_AGG(NULLIF(LTRIM(RTRIM(l.supplier_invoice_no)), ''), ', ') WITHIN GROUP (ORDER BY l.invoice_sno) AS supplier_invoice_nos,
               (SELECT STRING_AGG(d.po_no, ', ') FROM (SELECT DISTINCT po_no FROM #l WHERE payment_sno = pi.payment_sno AND po_no IS NOT NULL) d) AS po_nos,
               (SELECT STRING_AGG(d.gate_entry_nos, ', ') FROM (SELECT DISTINCT gate_entry_nos FROM #l WHERE payment_sno = pi.payment_sno AND gate_entry_nos IS NOT NULL) d) AS gate_entry_nos,
               (SELECT STRING_AGG(d.grn_nos, ', ') FROM (SELECT DISTINCT grn_nos FROM #l WHERE payment_sno = pi.payment_sno AND grn_nos IS NOT NULL) d) AS grn_nos,
               MIN(l.gate_entry_date) AS first_gate_entry_date, MIN(l.grn_date) AS first_grn_date, MIN(l.start_date) AS accepted_date,
               MIN(l.due_date) AS due_date, MIN(l.statutory_due) AS statutory_due_date
        FROM #l l WHERE l.payment_sno = pi.payment_sno
    ) agg;

    IF @view = 'run' AND @pay IS NULL
        SELECT * FROM #e ORDER BY msme_tier, CASE WHEN due_date IS NULL THEN 1 ELSE 0 END, due_date, accepted_date, net_paid, payment_sno;
    ELSE
        SELECT * FROM #e ORDER BY payment_sno DESC;

    SELECT l.payment_sno, l.invoice_sno, l.invoice_no, l.supplier_invoice_no, l.po_no, l.invoice_date, l.amount, l.bucket_type,
           l.gate_entry_nos, l.gate_entry_date, l.grn_nos, l.grn_date, l.start_date AS received_date, l.due_date
    FROM #l l WHERE @withLines = 1
    ORDER BY l.payment_sno, l.invoice_sno;

    SELECT setting_key, setting_value FROM dbo.nt_payment_run_setting;
END
GO
