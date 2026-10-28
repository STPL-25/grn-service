-- 69_advance_payment_flow.sql   (Non_trade_Dev ONLY - not applied to Non_Trade)
--
-- Advance payments.
--   * An advance agreed on a quotation is only a term; nothing ever paid it, so bills had nothing to net off. When the PO is approved
--     the advance now falls due as an 'Approved' ADVANCE payment (payment_info.payment_type) waiting in Payment Run, one per stage.
--   * Paying it in a run posts Dr Advance to Suppliers / Cr Bank and records the supplier advance (nt_supplier_advance_payment.payment_sno);
--     the PO's bill payments then net it off (the Payment screen pre-fills it).
--   * Supplier Portal: sp_nt_GetPaymentsForSupplier.
-- Changed procedures: sp_nt_CreatePaymentBatch, sp_nt_GetPaymentEntries, sp_nt_GetPaymentAdjustments (originals: backups/advance_payment_2026-10-23_ROLLBACK.sql).
-- Re-runnable.

IF COL_LENGTH('dbo.payment_info', 'payment_type') IS NULL ALTER TABLE dbo.payment_info ADD payment_type VARCHAR(10) NOT NULL CONSTRAINT DF_payment_info_type DEFAULT 'BILL';
GO
IF COL_LENGTH('dbo.payment_info', 'po_basic_sno') IS NULL ALTER TABLE dbo.payment_info ADD po_basic_sno INT NULL;
GO
IF COL_LENGTH('dbo.payment_info', 'adv_stage_no') IS NULL ALTER TABLE dbo.payment_info ADD adv_stage_no INT NULL;
GO
IF COL_LENGTH('dbo.payment_info', 'adv_due_date') IS NULL ALTER TABLE dbo.payment_info ADD adv_due_date DATE NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_payment_info_advance_stage' AND object_id = OBJECT_ID('dbo.payment_info'))
    CREATE UNIQUE INDEX UX_payment_info_advance_stage ON dbo.payment_info (po_basic_sno, adv_stage_no) WHERE payment_type = 'ADVANCE';
GO
IF COL_LENGTH('dbo.nt_supplier_advance_payment', 'payment_sno') IS NULL ALTER TABLE dbo.nt_supplier_advance_payment ADD payment_sno INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM dbo.nt_payment_run_setting WHERE setting_key = 'ADVANCE_FROM_DATE')
    INSERT INTO dbo.nt_payment_run_setting (setting_key, setting_value, description, modified_by)
    VALUES ('ADVANCE_FROM_DATE', '2026-10-23', 'POs dated on/after this day get their quotation advance as a payment in Payment Run; older POs are left alone.', 'system');
GO

-- ── approved POs with an advance -> advance payments waiting in Payment Run ────
-- The advance on a quotation (supplier_advance) is only a term. When its PO is approved the advance falls due: a payment_info row
-- of type ADVANCE, already 'Approved' (the PO approval is the authority), per stage (adv_issue_stages, else one stage for the whole
-- advance). It is paid in Payment Run like any payment; on paying, sp_nt_CreatePaymentBatch records it as a supplier advance
-- (nt_supplier_advance_payment) and the PO's bill payments net it off. A stage is created once: cancelling it leaves it cancelled.
-- Only POs dated on/after ADVANCE_FROM_DATE (nt_payment_run_setting) are picked up, so old test POs do not flood the run.
CREATE OR ALTER PROCEDURE dbo.sp_nt_SyncPoAdvancePayments
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @from DATE = ISNULL((SELECT TRY_CAST(setting_value AS DATE) FROM dbo.nt_payment_run_setting WHERE setting_key = 'ADVANCE_FROM_DATE'), '20261023');

    CREATE TABLE #c (po_basic_sno INT, po_no VARCHAR(40), vendor_sno INT, com_sno INT, div_sno INT, brn_sno INT, dept_sno INT, stage_no INT, amount DECIMAL(18,2), due_date DATE);

    ;WITH po AS (
        SELECT p.po_basic_sno, p.po_df_no, p.vendor_sno, p.com_sno, p.div_sno, p.brn_sno, p.dept_sno, CAST(p.po_date AS DATE) AS po_date,
               a.advance_payment_pct, a.gst_applicable, a.gst_pct, a.adv_issue_stages,
               ISNULL((SELECT SUM(i.total_amount) FROM dbo.supplier_quotation_items i WHERE i.sq_basic_sno = q.sq_basic_sno AND i.is_active = '1'), 0)
                 + ISNULL(q.freight_charges, 0) + ISNULL(q.other_charges, 0)
                 - CASE WHEN ISNULL(q.buyback_available, 0) = 1 THEN ISNULL(q.buyback_value, 0) ELSE 0 END AS base_total
        FROM dbo.po_request_info p
        JOIN dbo.supplier_quotation_info q ON q.pr_basic_sno = p.pr_basic_sno AND q.vendor_sno = p.vendor_sno AND q.is_selected = '1' AND q.is_active = '1' AND q.advance_payment_required = 1
        JOIN dbo.supplier_advance a ON a.sq_basic_sno = q.sq_basic_sno AND a.is_active = 'Y'
        WHERE p.status = 'A' AND p.is_active = 'Y' AND p.vendor_sno IS NOT NULL AND CAST(p.po_date AS DATE) >= @from
          AND NOT EXISTS (SELECT 1 FROM dbo.invoice_info ii JOIN dbo.invoice_allocation_details iad ON iad.invoice_sno = ii.invoice_sno
                          JOIN dbo.payment_allocation_details pad ON pad.invoice_alloc_sno = iad.invoice_alloc_sno WHERE ii.po_basic_sno = p.po_basic_sno)   -- a bill of this PO is already being paid: too late for an advance
    )
    INSERT INTO #c
    SELECT po.po_basic_sno, po.po_df_no, po.vendor_sno, po.com_sno, po.div_sno, po.brn_sno, po.dept_sno,
           TRY_CAST(JSON_VALUE(s.value, '$.stage_no') AS INT), TRY_CAST(JSON_VALUE(s.value, '$.amount') AS DECIMAL(18,2)),
           DATEADD(DAY, ISNULL(TRY_CAST(JSON_VALUE(s.value, '$.due_days') AS INT), 0), po.po_date)
    FROM po CROSS APPLY OPENJSON(CASE WHEN ISJSON(po.adv_issue_stages) = 1 THEN po.adv_issue_stages ELSE '[]' END) s;

    ;WITH po AS (
        SELECT p.po_basic_sno, p.po_df_no, p.vendor_sno, p.com_sno, p.div_sno, p.brn_sno, p.dept_sno, CAST(p.po_date AS DATE) AS po_date,
               a.advance_payment_pct, a.gst_applicable, a.gst_pct, a.adv_issue_stages,
               ISNULL((SELECT SUM(i.total_amount) FROM dbo.supplier_quotation_items i WHERE i.sq_basic_sno = q.sq_basic_sno AND i.is_active = '1'), 0)
                 + ISNULL(q.freight_charges, 0) + ISNULL(q.other_charges, 0)
                 - CASE WHEN ISNULL(q.buyback_available, 0) = 1 THEN ISNULL(q.buyback_value, 0) ELSE 0 END AS base_total
        FROM dbo.po_request_info p
        JOIN dbo.supplier_quotation_info q ON q.pr_basic_sno = p.pr_basic_sno AND q.vendor_sno = p.vendor_sno AND q.is_selected = '1' AND q.is_active = '1' AND q.advance_payment_required = 1
        JOIN dbo.supplier_advance a ON a.sq_basic_sno = q.sq_basic_sno AND a.is_active = 'Y'
        WHERE p.status = 'A' AND p.is_active = 'Y' AND p.vendor_sno IS NOT NULL AND CAST(p.po_date AS DATE) >= @from
          AND NOT EXISTS (SELECT 1 FROM dbo.invoice_info ii JOIN dbo.invoice_allocation_details iad ON iad.invoice_sno = ii.invoice_sno
                          JOIN dbo.payment_allocation_details pad ON pad.invoice_alloc_sno = iad.invoice_alloc_sno WHERE ii.po_basic_sno = p.po_basic_sno)   -- a bill of this PO is already being paid: too late for an advance
    )
    INSERT INTO #c
    SELECT po.po_basic_sno, po.po_df_no, po.vendor_sno, po.com_sno, po.div_sno, po.brn_sno, po.dept_sno, 1,
           ROUND(po.base_total * po.advance_payment_pct / 100.0 * (1 + CASE WHEN po.gst_applicable = 'Y' THEN ISNULL(po.gst_pct, 0) / 100.0 ELSE 0 END), 2), po.po_date
    FROM po WHERE NOT EXISTS (SELECT 1 FROM #c c WHERE c.po_basic_sno = po.po_basic_sno);

    DELETE FROM #c WHERE stage_no IS NULL OR amount IS NULL OR amount <= 0;
    DELETE c FROM #c c WHERE EXISTS (SELECT 1 FROM dbo.payment_info x WHERE x.payment_type = 'ADVANCE' AND x.po_basic_sno = c.po_basic_sno AND x.adv_stage_no = c.stage_no);
    IF NOT EXISTS (SELECT 1 FROM #c) RETURN;

    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @lk INT;
        EXEC @lk = sp_getapplock @Resource = N'pay_advance_sync', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 5000;
        IF @lk < 0 BEGIN ROLLBACK TRANSACTION; RETURN; END

        DECLARE @po INT, @st INT, @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT, @pno VARCHAR(30), @psno INT;
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT po_basic_sno, stage_no FROM #c ORDER BY po_basic_sno, stage_no;
        OPEN cur; FETCH NEXT FROM cur INTO @po, @st;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.payment_info WHERE payment_type = 'ADVANCE' AND po_basic_sno = @po AND adv_stage_no = @st)
            BEGIN
                SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(payment_no, 6) AS INT)), 0) + 1 FROM dbo.payment_info WITH (UPDLOCK, HOLDLOCK) WHERE payment_no LIKE 'PAY-' + @year + '-%';
                SET @pno = 'PAY-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);
                INSERT INTO dbo.payment_info (payment_no, vendor_sno, payment_date, amount, mode, status, remarks, is_active, created_by, created_date, approved_at,
                                              gross_amount, tds_amount, advance_adjusted, note_adjusted, net_paid, com_sno, div_sno, brn_sno, dept_sno,
                                              payment_type, po_basic_sno, adv_stage_no, adv_due_date)
                SELECT @pno, c.vendor_sno, c.due_date, c.amount, 'NEFT', 'Approved', LEFT('Advance for PO ' + c.po_no + CASE WHEN c.stage_no > 1 THEN ' (stage ' + CAST(c.stage_no AS VARCHAR(5)) + ')' ELSE '' END, 500),
                       'Y', 'SYSTEM', GETDATE(), GETDATE(), c.amount, 0, 0, 0, c.amount, c.com_sno, c.div_sno, c.brn_sno, c.dept_sno, 'ADVANCE', c.po_basic_sno, c.stage_no, c.due_date
                FROM #c c WHERE c.po_basic_sno = @po AND c.stage_no = @st;
                SET @psno = SCOPE_IDENTITY();
                INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment) VALUES (@psno, 'APPROVED', 'SYSTEM', N'Advance due on the approved PO - waiting in Payment Run');
            END
            FETCH NEXT FROM cur INTO @po, @st;
        END
        CLOSE cur; DEALLOCATE cur;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ── 3. what can be adjusted against a payment ───────────────────────────────
-- { vendor_sno, invoice_snos: [bills being paid] } -> 4 recordsets: advances, debit notes, credit notes, TDS sections
-- Without invoice_snos no note is offered (a note is only ever offered against specific bills).
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentAdjustments
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @v INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @bills NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.invoice_snos');
    SELECT advance_sno, advance_no, po_basic_sno, paid_date, amount, amount - adjusted_amount AS balance
    FROM dbo.nt_supplier_advance_payment WHERE vendor_sno = @v AND is_active = 'Y' AND amount - adjusted_amount > 0 ORDER BY paid_date, advance_sno;

    SELECT note_sno, note_no, po_basic_sno, grn_basic_sno, note_date, amount, remarks, scope, source_invoices
    FROM dbo.fn_nt_PaymentNotesForBills(@v, @bills) WHERE note_type = 'DEBIT' ORDER BY note_sno;

    SELECT note_sno, note_no, po_basic_sno, grn_basic_sno, note_date, amount, remarks, scope, source_invoices
    FROM dbo.fn_nt_PaymentNotesForBills(@v, @bills) WHERE note_type = 'CREDIT' ORDER BY note_sno;

    SELECT section_code, description, rate_individual, rate_other, rate_no_pan, single_threshold, annual_threshold, excess_only, is_active
    FROM dbo.tds_section_master ORDER BY section_code;

    -- advances approved for this supplier but not paid yet (waiting in Payment Run) - shown so the bill is not paid in full by mistake
    SELECT p.payment_sno, p.payment_no, p.po_basic_sno, po.po_df_no AS po_no, ISNULL(p.net_paid, p.amount) AS amount, p.status
    FROM dbo.payment_info p LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = p.po_basic_sno
    WHERE p.vendor_sno = @v AND p.payment_type = 'ADVANCE' AND p.is_active = 'Y' AND p.status = 'Approved' AND p.batch_sno IS NULL
    ORDER BY p.payment_sno;
END
GO

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

-- ── 3. the run: pay what today's fund covers ────────────────────────────────
-- @jsonInput: { payment_snos: [..in the order they should appear in the file], fund_plan_amount, created_by, payment_date?, hierarchy?,
--               payment_bank_sno? }   (payment_bank_sno: the account to pay from; default = the company's default / only account)
-- Marks the payments 'Processed', snapshots the payee bank details, and posts each payment's journal. -> batch row, items.
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreatePaymentBatch
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @list NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.payment_snos'),
            @fund DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.fund_plan_amount') AS DECIMAL(18,2)),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by'),
            @vdate DATE = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_date') AS DATE), CAST(GETDATE() AS DATE)),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'),
            @bank_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_bank_sno') AS INT);
    IF @by IS NULL THROW 56100, 'created_by is required.', 1;

    DECLARE @raw TABLE (line_no INT, payment_sno INT);
    INSERT INTO @raw SELECT TRY_CAST(j.[key] AS INT) + 1, TRY_CAST(j.value AS INT) FROM OPENJSON(@list) j;
    IF NOT EXISTS (SELECT 1 FROM @raw) OR EXISTS (SELECT 1 FROM @raw WHERE payment_sno IS NULL) THROW 56101, 'Select at least one payment.', 1;
    DECLARE @sel TABLE (line_no INT, payment_sno INT PRIMARY KEY);
    INSERT INTO @sel SELECT MIN(line_no), payment_sno FROM @raw GROUP BY payment_sno;
    IF @fund IS NULL OR @fund <= 0 THROW 56103, 'Enter today''s fund plan before proceeding.', 1;

    DECLARE @h_pay INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'SUPPLIER_PAYABLE'),
            @h_tds INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'TDS_PAYABLE'),
            @h_adv INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'ADVANCE_SUPPLIER'),
            @h_bank INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'BANK'),
            @h_dn INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'DN_ADJ');
    IF @h_pay IS NULL OR @h_tds IS NULL OR @h_adv IS NULL OR @h_bank IS NULL OR @h_dn IS NULL THROW 56108, 'System account heads are missing.', 1;

    DECLARE @bsno INT, @bno VARCHAR(30);
    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @lk INT;
        EXEC @lk = sp_getapplock @Resource = N'pay_run_batch', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
        IF @lk < 0 THROW 56107, 'Another payment run is being created right now - please try again in a moment.', 1;

        DECLARE @bad NVARCHAR(500) = (
            SELECT STRING_AGG(ISNULL(pi.payment_no, CAST(s.payment_sno AS VARCHAR(12))), ', ')
            FROM @sel s LEFT JOIN dbo.payment_info pi WITH (UPDLOCK, HOLDLOCK) ON pi.payment_sno = s.payment_sno
            WHERE pi.payment_sno IS NULL OR pi.is_active <> 'Y' OR pi.status <> 'Approved' OR pi.batch_sno IS NOT NULL);
        IF @bad IS NOT NULL
        BEGIN
            DECLARE @badMsg NVARCHAR(700) = N'No longer waiting for payment (already paid, cancelled, or not approved): ' + @bad + N'. Refresh the list.';
            THROW 56102, @badMsg, 1;
        END

        IF @hier IS NOT NULL AND EXISTS (
            SELECT 1 FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno
            WHERE NOT EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                              WHERE h.com_sno = pi.com_sno AND (h.div_sno IS NULL OR h.div_sno = pi.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = pi.brn_sno)))
            THROW 56110, 'You do not have access to one or more of the selected payments.', 1;

        IF (SELECT COUNT(*) FROM (SELECT DISTINCT ISNULL(pi.com_sno, -1) com_sno, ISNULL(pi.div_sno, -1) div_sno, ISNULL(pi.brn_sno, -1) brn_sno
                                  FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno) scopes) > 1
            THROW 56105, 'A payment file covers one company, division and branch at a time - untick payments from the other scope.', 1;

        DECLARE @total DECIMAL(18,2) = (SELECT SUM(ISNULL(pi.net_paid, pi.amount)) FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno);
        IF @total > @fund + 0.005
        BEGIN
            DECLARE @fundMsg NVARCHAR(300) = N'The selected payments total ' + FORMAT(@total, 'N2') + N', more than the fund plan of ' + FORMAT(@fund, 'N2') + N'.';
            THROW 56104, @fundMsg, 1;
        END

        -- a bank transfer needs the supplier's bank account
        DECLARE @nobank NVARCHAR(500) = (
            SELECT STRING_AGG(ISNULL(k.company_name, '?') + ' (' + pi.payment_no + ')', ', ')
            FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno
            LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pi.vendor_sno
            WHERE ISNULL(pi.net_paid, pi.amount) > 0 AND ISNULL(k.pay_via_portal, 'N') <> 'Y' AND UPPER(pi.mode) NOT IN ('CHEQUE', 'CASH', 'DD')
              AND NOT EXISTS (SELECT 1 FROM dbo.kyc_bank_info x WHERE x.kyc_basic_info_sno = pi.vendor_sno AND ISNULL(x.is_active, 'Y') = 'Y'
                              AND x.ac_number IS NOT NULL AND NULLIF(LTRIM(RTRIM(x.ifsc)), '') IS NOT NULL));
        IF @nobank IS NOT NULL
        BEGIN
            DECLARE @nobankMsg NVARCHAR(700) = N'Supplier bank details (account number and IFSC) are missing for: ' + @nobank + N'. Update the supplier KYC, or untick them.';
            THROW 56106, @nobankMsg, 1;
        END

        -- the sender: which of the company's bank accounts this run is paid from. Needed only when the file will hold a bank
        -- transfer (a NEFT / RTGS payment to a supplier's account); a run of cheques, cash, portal payments and adjustments has no file.
        DECLARE @com INT = (SELECT MIN(pi.com_sno) FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno),
                @div INT = (SELECT MIN(pi.div_sno) FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno),
                @brn INT = (SELECT MIN(pi.brn_sno) FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno);
        DECLARE @file_lines INT = (
            SELECT COUNT(*) FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno
            LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pi.vendor_sno
            WHERE ISNULL(pi.net_paid, pi.amount) > 0 AND ISNULL(k.pay_via_portal, 'N') <> 'Y' AND UPPER(pi.mode) IN ('NEFT', 'RTGS'));
        DECLARE @pb INT = NULL, @pb_type VARCHAR(20), @pb_prefix VARCHAR(30), @pb_client VARCHAR(30), @pb_file_code INT,
                @pb_email VARCHAR(100), @pb_bank NVARCHAR(100), @pb_acno VARCHAR(30);
        IF @file_lines > 0
        BEGIN
            IF @bank_sno IS NOT NULL
            BEGIN
                SELECT @pb = payment_bank_sno FROM dbo.payment_bank_master
                WHERE payment_bank_sno = @bank_sno AND is_active = 'Y' AND com_sno = @com AND div_sno = @div AND brn_sno = @brn;
                IF @pb IS NULL THROW 56113, N'The chosen bank account is not available for this company/division/branch (or it was switched off). Choose another.', 1;
            END
            ELSE
            BEGIN
                SELECT @pb = payment_bank_sno FROM dbo.payment_bank_master
                WHERE is_active = 'Y' AND com_sno = @com AND div_sno = @div AND brn_sno = @brn AND is_default = 'Y';
                IF @pb IS NULL
                BEGIN
                    DECLARE @n_banks INT = (SELECT COUNT(*) FROM dbo.payment_bank_master WHERE is_active = 'Y' AND com_sno = @com AND div_sno = @div AND brn_sno = @brn);
                    IF @n_banks = 0 THROW 56111, N'No bank account is set up for this company/division/branch. Add one in Masters > Payment Bank, then run again.', 1;
                    IF @n_banks > 1 THROW 56112, N'This company/division/branch has more than one bank account - choose which one this run is paid from.', 1;
                    SELECT @pb = payment_bank_sno FROM dbo.payment_bank_master WHERE is_active = 'Y' AND com_sno = @com AND div_sno = @div AND brn_sno = @brn;
                END
            END
            SELECT @pb_type = file_type, @pb_prefix = file_prefix, @pb_client = client_code, @pb_file_code = file_code,
                   @pb_email = alert_email, @pb_bank = bank_name, @pb_acno = ac_number
            FROM dbo.payment_bank_master WHERE payment_bank_sno = @pb;
            IF @pb_type <> 'BANK_UPLOAD' THROW 56114, N'This bank account has a payment file type the run cannot write yet.', 1;
        END

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(batch_no, 6) AS INT)), 0) + 1 FROM dbo.payment_batch WITH (UPDLOCK, HOLDLOCK) WHERE batch_no LIKE 'PB-' + @year + '-%';
        SET @bno = 'PB-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

        -- The file name: <prefix>_<client>_<client><DDMM>.<seq>. Reserve its number in the daily register while the run lock
        -- is held. The unique constraint is a second concurrency guard, independent of payment_batch/file-name parsing.
        DECLARE @fname VARCHAR(200) = NULL, @fseq INT = NULL, @file_creation_sno BIGINT = NULL;
        IF @pb IS NOT NULL
        BEGIN
            DECLARE @base VARCHAR(120) = @pb_prefix + '_' + @pb_client + '_' + @pb_client
                                         + RIGHT('0' + CAST(DAY(@vdate) AS VARCHAR(2)), 2) + RIGHT('0' + CAST(MONTH(@vdate) AS VARCHAR(2)), 2);
            SELECT @fseq = ISNULL(MAX(file_no) + 1, @pb_file_code)
            FROM dbo.payment_file_creation_no WITH (UPDLOCK, HOLDLOCK)
            WHERE file_prefix = @pb_prefix AND client_code = @pb_client AND file_date = @vdate;
            IF @fseq < @pb_file_code SET @fseq = @pb_file_code;
            SET @fname = @base + '.' + CAST(@fseq AS VARCHAR(10));
            INSERT INTO dbo.payment_file_creation_no (payment_bank_sno, file_prefix, client_code, file_date, file_no, file_name, created_by)
            VALUES (@pb, @pb_prefix, @pb_client, @vdate, @fseq, @fname, @by);
            SET @file_creation_sno = SCOPE_IDENTITY();
        END

        INSERT INTO dbo.payment_batch (batch_no, batch_date, com_sno, div_sno, brn_sno, fund_plan_amount, total_amount, item_count, status, created_by,
                                       file_name, file_no, payment_bank_sno, file_type, sender_client_code, sender_alert_email, sender_bank_name, sender_account_no)
        SELECT @bno, @vdate, MIN(pi.com_sno), MIN(pi.div_sno), MIN(pi.brn_sno), @fund, @total, COUNT(*), 'Generated', @by,
               @fname, @fseq, @pb, @pb_type, @pb_client, @pb_email, @pb_bank, @pb_acno
        FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno;
        SET @bsno = SCOPE_IDENTITY();
        IF @file_creation_sno IS NOT NULL
            UPDATE dbo.payment_file_creation_no SET batch_sno = @bsno WHERE payment_file_creation_sno = @file_creation_sno;

        INSERT INTO dbo.payment_batch_item (batch_sno, payment_sno, line_no, vendor_sno, vendor_name, supp_code, vendor_email, amount, mode, debit_account, channel,
                                            beneficiary_name, account_no, ifsc, bank_name, branch_name, invoice_nos, supplier_invoice_nos, msme_label, narration)
        SELECT @bsno, pi.payment_sno, ROW_NUMBER() OVER (ORDER BY s.line_no), pi.vendor_sno, k.company_name, k.supp_code, k.email,
               ISNULL(pi.net_paid, pi.amount), pi.mode, pi.bank_account, ch.channel,
               CASE WHEN ch.channel = 'BANK' THEN bk.ac_holder_name END, CASE WHEN ch.channel = 'BANK' THEN CAST(bk.ac_number AS VARCHAR(40)) END,
               CASE WHEN ch.channel = 'BANK' THEN bk.ifsc END, CASE WHEN ch.channel = 'BANK' THEN bk.bank_name END, CASE WHEN ch.channel = 'BANK' THEN bk.bank_branch_name END,
               inv.invoice_nos, inv.supplier_invoice_nos,
               CASE WHEN ISNULL(k.is_msme_avail, 'N') = 'Y' OR NULLIF(LTRIM(RTRIM(k.msme_type)), '') IS NOT NULL THEN ISNULL(NULLIF(LTRIM(RTRIM(k.msme_type)), ''), 'MSME') END,
               LEFT(pi.payment_no + ISNULL(' ' + inv.first_supplier_invoice, ''), 60)
        FROM @sel s
        JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno
        LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pi.vendor_sno
        OUTER APPLY (SELECT TOP 1 x.ac_holder_name, x.ac_number, x.ifsc, x.bank_name, x.bank_branch_name
                     FROM dbo.kyc_bank_info x
                     WHERE x.kyc_basic_info_sno = pi.vendor_sno AND ISNULL(x.is_active, 'Y') = 'Y'
                       AND x.ac_number IS NOT NULL AND NULLIF(LTRIM(RTRIM(x.ifsc)), '') IS NOT NULL   -- same test as the 56106 guard: the account snapshotted is one the guard accepted
                     ORDER BY CASE WHEN x.is_primary = 'Y' THEN 0 ELSE 1 END, x.kyc_address_sno DESC) bk
        CROSS APPLY (SELECT CASE WHEN ISNULL(pi.net_paid, pi.amount) = 0 THEN 'ADJUSTMENT'
                                 WHEN k.pay_via_portal = 'Y' THEN 'PORTAL'
                                 WHEN UPPER(pi.mode) IN ('CHEQUE', 'CASH', 'DD') THEN 'MANUAL'
                                 ELSE 'BANK' END AS channel) ch
        OUTER APPLY (SELECT STRING_AGG(l.invoice_no, ', ') WITHIN GROUP (ORDER BY l.invoice_sno) AS invoice_nos,
                            STRING_AGG(NULLIF(LTRIM(RTRIM(l.supplier_invoice_no)), ''), ', ') WITHIN GROUP (ORDER BY l.invoice_sno) AS supplier_invoice_nos,
                            MIN(NULLIF(LTRIM(RTRIM(l.supplier_invoice_no)), '')) AS first_supplier_invoice
                     FROM dbo.fn_nt_PaymentLines(pi.payment_sno) l) inv;

        UPDATE pi SET status = 'Processed', batch_sno = @bsno, processed_at = GETDATE(), payment_date = @vdate, modified_by = @by, modified_date = GETDATE()
        FROM dbo.payment_info pi JOIN @sel s ON s.payment_sno = pi.payment_sno;
        INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment)
        SELECT s.payment_sno, 'PAID', @by, N'Paid in ' + @bno FROM @sel s;

        -- journals: the same entries the release used to post
        DECLARE @jl TABLE (head_sno INT, debit DECIMAL(18,2), credit DECIMAL(18,2));
        DECLARE @ptype VARCHAR(10), @ppo INT, @advsno INT, @p INT, @pn VARCHAR(30), @pv INT, @gross DECIMAL(18,2), @tds DECIMAL(18,2), @adv DECIMAL(18,2), @net DECIMAL(18,2), @dn DECIMAL(18,2), @cn DECIMAL(18,2),
                @jc INT, @jd INT, @jb INT, @jdp INT, @j INT;
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT payment_sno FROM @sel ORDER BY line_no;
        OPEN cur; FETCH NEXT FROM cur INTO @p;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @pn = payment_no, @pv = vendor_sno, @gross = ISNULL(gross_amount, amount), @tds = ISNULL(tds_amount, 0), @adv = ISNULL(advance_adjusted, 0),
                   @net = ISNULL(net_paid, amount), @jc = com_sno, @jd = div_sno, @jb = brn_sno, @jdp = dept_sno, @ptype = ISNULL(payment_type, 'BILL'), @ppo = po_basic_sno
            FROM dbo.payment_info WHERE payment_sno = @p;
            SELECT @dn = ISNULL(SUM(CASE WHEN adj_type = 'DEBIT_NOTE' THEN amount END), 0), @cn = ISNULL(SUM(CASE WHEN adj_type = 'CREDIT_NOTE' THEN amount END), 0)
            FROM dbo.payment_adjustment WHERE payment_sno = @p;

            INSERT INTO dbo.acct_journal (journal_date, source_type, source_sno, narration, com_sno, div_sno, brn_sno, dept_sno, created_by)
            VALUES (@vdate, 'PAYMENT', @p, N'Payment ' + @pn, @jc, @jd, @jb, @jdp, @by);
            SET @j = SCOPE_IDENTITY();
            UPDATE dbo.acct_journal SET journal_no = 'JV-' + RIGHT('000000' + CAST(@j AS VARCHAR(6)), 6) WHERE journal_sno = @j;

            DELETE FROM @jl;
            IF @ptype = 'ADVANCE'
            BEGIN   -- an advance paid to the supplier: Dr Advance to Suppliers / Cr Bank (it is netted against the PO's bills later)
                INSERT INTO @jl VALUES (@h_adv, @net, 0);
                INSERT INTO @jl VALUES (@h_bank, 0, @net);
            END
            ELSE
            BEGIN
            INSERT INTO @jl VALUES (@h_pay, @gross + @cn, 0);
            IF @tds > 0 INSERT INTO @jl VALUES (@h_tds, 0, @tds);
            IF @adv > 0 INSERT INTO @jl VALUES (@h_adv, 0, @adv);
            IF @net > 0 INSERT INTO @jl VALUES (@h_bank, 0, @net);
            IF @dn > 0  INSERT INTO @jl VALUES (@h_dn, 0, @dn);
            IF @cn > 0  BEGIN INSERT INTO @jl VALUES (@h_dn, @cn, 0); INSERT INTO @jl VALUES (@h_pay, 0, @cn); END
            END
            IF (SELECT SUM(debit) - SUM(credit) FROM @jl) <> 0 THROW 56109, 'Payment journal is not balanced.', 1;
            INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno) SELECT @j, head_sno, debit, credit, @pv FROM @jl;
            UPDATE dbo.payment_info SET journal_sno = @j WHERE payment_sno = @p;

            IF @ptype = 'ADVANCE'
            BEGIN   -- the money is out: it is now a supplier advance that the PO's bill payments net off
                INSERT INTO dbo.nt_supplier_advance_payment (vendor_sno, po_basic_sno, paid_date, amount, mode, reference_no, remarks, journal_sno, payment_sno, created_by)
                SELECT vendor_sno, po_basic_sno, @vdate, ISNULL(net_paid, amount), mode, @pn, remarks, @j, payment_sno, @by FROM dbo.payment_info WHERE payment_sno = @p;
                SET @advsno = SCOPE_IDENTITY();
                UPDATE dbo.nt_supplier_advance_payment SET advance_no = 'ADV-' + RIGHT('000000' + CAST(@advsno AS VARCHAR(6)), 6) WHERE advance_sno = @advsno;
            END

            FETCH NEXT FROM cur INTO @p;
        END
        CLOSE cur; DEALLOCATE cur;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT b.batch_sno, b.batch_no, b.batch_date, b.com_sno, b.div_sno, b.brn_sno, b.fund_plan_amount, b.total_amount, b.item_count, b.status, b.created_by,
           CONVERT(VARCHAR(30), b.created_at, 120) AS created_at,
           b.file_name, b.file_no, b.payment_bank_sno, b.file_type, b.sender_client_code, b.sender_alert_email, b.sender_bank_name, b.sender_account_no
    FROM dbo.payment_batch b WHERE b.batch_sno = @bsno;
    SELECT i.batch_item_sno, i.batch_sno, i.payment_sno, p.payment_no, i.line_no, i.vendor_sno, i.vendor_name, i.supp_code, i.vendor_email, i.amount, i.mode, i.debit_account,
           i.channel, i.beneficiary_name, i.account_no, i.ifsc, i.bank_name, i.branch_name, i.invoice_nos, i.supplier_invoice_nos, i.msme_label, i.narration,
           p.com_sno, p.div_sno, p.brn_sno, p.dept_sno
    FROM dbo.payment_batch_item i JOIN dbo.payment_info p ON p.payment_sno = i.payment_sno
    WHERE i.batch_sno = @bsno ORDER BY i.line_no;
END
GO

-- ── Supplier Portal: the supplier's own payments ───────────────────────────
-- { kyc_basic_info_sno } -> 2 recordsets: payments (approved = scheduled, processed = paid; internal approval stages are not shown),
-- advances (paid to the supplier, how much is netted off bills, what is left).
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentsForSupplier
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @v INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno') AS INT);
    IF @v IS NULL THROW 56200, 'kyc_basic_info_sno is required.', 1;

    SELECT p.payment_sno, p.payment_no, ISNULL(p.payment_type, 'BILL') AS payment_type,
           CASE p.status WHEN 'Processed' THEN 'Paid' ELSE 'Scheduled' END AS status,
           p.payment_date, p.processed_at, b.batch_no, p.mode,
           ISNULL(p.gross_amount, p.amount) AS gross_amount, ISNULL(p.tds_amount, 0) AS tds_amount, ISNULL(p.advance_adjusted, 0) AS advance_adjusted,
           ISNULL(p.note_adjusted, 0) AS note_adjusted, ISNULL(p.net_paid, p.amount) AS net_paid,
           COALESCE(po.po_df_no, l.po_nos) AS po_nos, l.invoice_nos, l.supplier_invoice_nos,
           CASE WHEN p.status = 'Approved' AND p.payment_type = 'ADVANCE' THEN p.adv_due_date END AS planned_for
    FROM dbo.payment_info p
    LEFT JOIN dbo.payment_batch b ON b.batch_sno = p.batch_sno
    LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = p.po_basic_sno AND p.payment_type = 'ADVANCE'
    OUTER APPLY (SELECT STRING_AGG(x.invoice_no, ', ') AS invoice_nos, STRING_AGG(NULLIF(LTRIM(RTRIM(x.supplier_invoice_no)), ''), ', ') AS supplier_invoice_nos,
                        STRING_AGG(x.po_no, ', ') AS po_nos
                 FROM dbo.fn_nt_PaymentLines(p.payment_sno) x) l
    WHERE p.vendor_sno = @v AND p.is_active = 'Y' AND p.status IN ('Approved', 'Processed')
    ORDER BY ISNULL(p.processed_at, p.created_date) DESC, p.payment_sno DESC;

    SELECT a.advance_sno, a.advance_no, a.po_basic_sno, po.po_df_no AS po_no, a.paid_date, a.amount, a.adjusted_amount, a.amount - a.adjusted_amount AS balance, a.remarks
    FROM dbo.nt_supplier_advance_payment a LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = a.po_basic_sno
    WHERE a.vendor_sno = @v AND a.is_active = 'Y'
    ORDER BY a.advance_sno DESC;
END
GO
