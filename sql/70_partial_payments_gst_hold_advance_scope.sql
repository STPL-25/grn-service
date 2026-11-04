-- sql/70: part payments, GST held until GSTR-2B, advances stay with their PO, per-invoice snapshot for the payment file checkers.
--
--  * A bill can be paid in part (the Payment screen asks for the amount); the approver can pay less now and keep the rest for later
--    (sp_nt_ReleasePaymentNet with revise_payment_sno).
--  * An invoice that is not in GSTR-2B yet can be paid up to its taxable value; the GST part follows once 2B has the invoice.
--    (an invoice with no taxable value cannot be split - nothing is payable before 2B, as before)
--  * TDS base is taxable-first, so GST paid later carries no second TDS.
--  * An advance is subtracted on its own PO's invoices; if the PO is cancelled / closed it moves to the supplier's other invoices.
--    Debit / credit notes of a cancelled PO's invoices likewise become the supplier's to use anywhere.
--  * Each payment run keeps, per invoice: paid before, paid now, TDS, balance left (payment_batch_item_invoice) - the bank file and the
--    verification sheet are built from it.
-- Re-runnable.  Rollback: sql/backups/partial_payments_2026-10-24_ROLLBACK.sql

-- ── 1. tables / columns ─────────────────────────────────────────────────────
-- What a payment run paid on each invoice, frozen when the run is made: it is what the auditor / payment inputter checks the
-- bank file against (the bank screen only shows the file's lines, not this application).
IF OBJECT_ID('dbo.payment_batch_item_invoice') IS NULL
BEGIN
    CREATE TABLE dbo.payment_batch_item_invoice (
        batch_item_invoice_sno INT IDENTITY(1,1) PRIMARY KEY,
        batch_item_sno   INT NOT NULL,
        batch_sno        INT NOT NULL,
        payment_sno      INT NOT NULL,
        invoice_sno      INT NOT NULL,
        invoice_no       VARCHAR(30) NULL,
        supplier_invoice_no VARCHAR(50) NULL,
        invoice_date     DATE NULL,
        invoice_amount   DECIMAL(18,2) NULL,   -- as entered on the invoice
        gst_amount       DECIMAL(18,2) NULL,   -- invoice amount - taxable value (NULL when the invoice carries no taxable value)
        payable_total    DECIMAL(18,2) NOT NULL, -- what the invoice may be paid in all (release amount of its allocations)
        paid_before      DECIMAL(18,2) NOT NULL, -- paid by earlier payments
        this_gross       DECIMAL(18,2) NOT NULL, -- paid by this payment, before TDS / advance / notes
        tds_amount       DECIMAL(18,2) NOT NULL,
        balance_after    DECIMAL(18,2) NOT NULL, -- still to pay on the invoice after this payment
        awaiting_2b      BIT NOT NULL,           -- part of the balance is GST waiting for the invoice to show in GSTR-2B
        part_no          INT NOT NULL,           -- 1 = first payment on this invoice
        kind             VARCHAR(5) NOT NULL     -- FULL (whole invoice at once) | PART (more to come) | FINAL (last part)
    );
    CREATE INDEX IX_pbii_batch ON dbo.payment_batch_item_invoice (batch_sno, batch_item_sno);
END
GO
IF COL_LENGTH('dbo.payment_batch_item', 'gross_amount') IS NULL
    ALTER TABLE dbo.payment_batch_item ADD gross_amount DECIMAL(18,2) NULL, tds_amount DECIMAL(18,2) NULL, advance_amount DECIMAL(18,2) NULL, note_amount DECIMAL(18,2) NULL;
GO

-- ── 2. what can be paid on one bill right now ───────────────────────────────
-- settled / reserved: money already paid / held by a saved or approved payment.  A GST-registered supplier's invoice that has not
-- shown in GSTR-2B yet (and Accounts has not released the hold) may be paid only up to its taxable part; the GST part is paid once
-- 2B has it.  An invoice with no taxable value on it cannot be split, so nothing of it is payable before 2B (as before).
--   taxable_part  the share of this bill that is taxable value (the whole bill when the invoice carries no taxable value) - TDS base
--   gst_part      the rest (GST and anything else on top of the taxable value)
--   hold_2b       what may not be paid yet because 2B does not have the invoice
--   payable_now   what can be paid now: release - hold_2b - settled - reserved
CREATE OR ALTER FUNCTION dbo.fn_nt_BillPayable (@invoice_alloc_sno INT)
RETURNS TABLE
AS
RETURN
(
    SELECT iad.invoice_alloc_sno, iad.invoice_sno, iad.release_amount,
           pd.settled, pd.reserved,
           CAST(iad.release_amount - pd.settled - pd.reserved AS DECIMAL(18,2)) AS outstanding,
           x.on_hold_2b, x.taxable_known,
           t.taxable_part, CAST(iad.release_amount - t.taxable_part AS DECIMAL(18,2)) AS gst_part,
           h.hold_2b,
           CAST(CASE WHEN iad.release_amount - h.hold_2b - pd.settled - pd.reserved > 0 THEN iad.release_amount - h.hold_2b - pd.settled - pd.reserved ELSE 0 END AS DECIMAL(18,2)) AS payable_now
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    OUTER APPLY (
        SELECT ISNULL(SUM(CASE WHEN pyi.status IN ('Pending Approval', 'Approved') THEN 0 ELSE pad.amount END), 0) AS settled,
               ISNULL(SUM(CASE WHEN pyi.status IN ('Pending Approval', 'Approved') THEN pad.amount ELSE 0 END), 0) AS reserved
        FROM dbo.payment_allocation_details pad
        JOIN dbo.payment_info pyi ON pyi.payment_sno = pad.payment_sno
        WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno
    ) pd
    CROSS APPLY (
        SELECT CAST(CASE WHEN LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(i.itc_status, '') NOT IN ('Eligible', 'Ineligible')
                              AND ISNULL(i.payment_hold_override, 'N') <> 'Y' THEN 1 ELSE 0 END AS BIT) AS on_hold_2b,
               CAST(CASE WHEN ISNULL(i.invoice_amount, 0) > 0 AND i.taxable_value IS NOT NULL AND i.taxable_value > 0 AND i.taxable_value <= i.invoice_amount THEN 1 ELSE 0 END AS BIT) AS taxable_known
    ) x
    CROSS APPLY (
        SELECT CAST(CASE WHEN x.taxable_known = 1 THEN ROUND(iad.release_amount * i.taxable_value / i.invoice_amount, 2) ELSE iad.release_amount END AS DECIMAL(18,2)) AS taxable_part
    ) t
    CROSS APPLY (
        SELECT CAST(CASE WHEN x.on_hold_2b = 0 THEN 0
                         WHEN x.taxable_known = 1 THEN iad.release_amount - t.taxable_part
                         ELSE iad.release_amount END AS DECIMAL(18,2)) AS hold_2b
    ) h
    WHERE (@invoice_alloc_sno IS NULL OR iad.invoice_alloc_sno = @invoice_alloc_sno)
);
GO

-- ── 3. advances a payment may use ───────────────────────────────────────────
-- An advance is paid against one PO and is subtracted on THAT PO's invoices (scope 'OWN').  It moves to the supplier's other
-- invoices (scope 'SUPPLIER') only when its PO is not going forward: the PO is cancelled / no longer active, every invoice of the
-- PO was cancelled, or every live invoice of the PO is already paid in full (so the rest of the advance can never be used there).
-- @invoice_json = JSON array of the invoice_sno being paid.  With no invoices nothing is offered.
CREATE OR ALTER FUNCTION dbo.fn_nt_PaymentAdvancesForBills (@vendor_sno INT, @invoice_json NVARCHAR(MAX))
RETURNS TABLE
AS
RETURN
(
    WITH sel AS (
        SELECT DISTINCT i.po_basic_sno
        FROM OPENJSON(@invoice_json) j
        JOIN dbo.invoice_info i ON i.invoice_sno = TRY_CAST(j.value AS INT) AND i.vendor_sno = @vendor_sno AND i.is_active = 'Y'
        WHERE i.po_basic_sno IS NOT NULL
    ),
    adv AS (
        SELECT a.advance_sno, a.advance_no, a.po_basic_sno, a.paid_date, a.amount, CAST(a.amount - a.adjusted_amount AS DECIMAL(18,2)) AS balance
        FROM dbo.nt_supplier_advance_payment a
        WHERE a.vendor_sno = @vendor_sno AND a.is_active = 'Y' AND a.amount - a.adjusted_amount > 0
    )
    SELECT x.advance_sno, x.advance_no, x.po_basic_sno, po.po_df_no AS po_no, x.paid_date, x.amount, x.balance, x.scope
    FROM (
        SELECT a.advance_sno, a.advance_no, a.po_basic_sno, a.paid_date, a.amount, a.balance,
               CAST(CASE WHEN EXISTS (SELECT 1 FROM sel WHERE sel.po_basic_sno = a.po_basic_sno) THEN 'OWN'
                         WHEN a.po_basic_sno IS NULL OR p.po_basic_sno IS NULL OR p.is_active <> 'Y' OR p.status NOT IN ('A', 'P') THEN 'SUPPLIER'
                         WHEN st.any_count > 0 AND st.live_count = 0 THEN 'SUPPLIER'
                         WHEN st.live_count > 0 AND st.open_count = 0 THEN 'SUPPLIER'
                    END AS VARCHAR(8)) AS scope
        FROM adv a
        LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = a.po_basic_sno
        OUTER APPLY (
            SELECT COUNT(*) AS any_count,
                   SUM(CASE WHEN i.is_active = 'Y' THEN 1 ELSE 0 END) AS live_count,
                   SUM(CASE WHEN i.is_active = 'Y' AND ISNULL(c.is_closed, 0) = 0 THEN 1 ELSE 0 END) AS open_count
            FROM dbo.invoice_info i
            OUTER APPLY (
                SELECT CASE WHEN COUNT(*) > 0 AND SUM(ISNULL(pd.paid, 0)) > 0 AND SUM(iad.release_amount) - SUM(ISNULL(pd.paid, 0)) <= 0.01 THEN 1 ELSE 0 END AS is_closed
                FROM dbo.invoice_allocation_details iad
                OUTER APPLY (SELECT SUM(pad.amount) AS paid
                             FROM dbo.payment_allocation_details pad
                             JOIN dbo.payment_info pyi ON pyi.payment_sno = pad.payment_sno AND pyi.status NOT IN ('Pending Approval', 'Approved', 'Rejected', 'Cancelled')
                             WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno) pd
                WHERE iad.invoice_sno = i.invoice_sno AND iad.is_active = 'Y'
            ) c
            WHERE i.po_basic_sno = a.po_basic_sno AND i.vendor_sno = @vendor_sno
        ) st
    ) x
    LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = x.po_basic_sno
    WHERE x.scope IS NOT NULL
);
GO

-- ── 4. Payment screen list: adds what can be paid now ───────────────────────
-- Same as before plus: gst_amount (the GST share of the bill), gst_held (the part kept back until the invoice shows in GSTR-2B),
-- payable_now (what can be paid today; below `outstanding` while the GST is held) and taxable_known.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPayableBillsNet
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);

    BEGIN TRY
        EXEC dbo.sp_nt_SyncServicePoInvoicesToPayables;
    END TRY
    BEGIN CATCH
        -- a sync problem must never take the whole Payment list down
    END CATCH

    SELECT
        iad.invoice_alloc_sno AS bill_sno, i.invoice_sno, i.invoice_no AS bill_no, i.vendor_invoice_no AS supplier_invoice_no,
        p.po_df_no AS po_no, i.vendor_sno, k.company_name AS vendor_name, i.invoice_date, i.due_date, iad.bucket_type,
        iad.allocated_amount, iad.hold_amount, iad.release_amount AS net_payable,
        paid.paidSoFar AS paid_amount, paid.reservedSoFar AS reserved_amount,
        iad.release_amount - paid.paidSoFar - paid.reservedSoFar AS outstanding,
        i.invoice_amount, i.taxable_value, i.tds_section_code, i.itc_status, i.payment_hold_override,
        CAST(CASE WHEN LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 THEN 1 ELSE 0 END AS BIT) AS gst_supplier,
        CAST(CASE WHEN i.gst_journal_sno IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS gst_booked,
        CASE WHEN iad.bucket_type = 'SERVICE' THEN 'NA'
             WHEN EXISTS (SELECT 1 FROM dbo.grn_basic_info g WHERE g.po_basic_sno = i.po_basic_sno AND g.is_active = 'Y' AND g.status IN ('Approved', 'Received')) THEN 'Done'
             WHEN EXISTS (SELECT 1 FROM dbo.grn_basic_info g WHERE g.po_basic_sno = i.po_basic_sno AND g.is_active = 'Y' AND g.status = 'Pending Approval') THEN 'Pending approval'
             ELSE 'No GRN' END AS grn_state,
        CAST(CASE WHEN LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(i.itc_status, '') NOT IN ('Eligible', 'Ineligible')
                       AND ISNULL(i.payment_hold_override, 'N') <> 'Y' THEN 1 ELSE 0 END AS BIT) AS on_hold_2b,
        CASE WHEN bp.on_hold_2b = 1 AND bp.taxable_known = 1 THEN bp.gst_part ELSE 0 END AS gst_held,
        bp.gst_part AS gst_amount, bp.taxable_known, bp.payable_now
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    OUTER APPLY (
        SELECT ISNULL(SUM(CASE WHEN pyi.status IN ('Pending Approval', 'Approved') THEN 0 ELSE pad.amount END), 0) AS paidSoFar,
               ISNULL(SUM(CASE WHEN pyi.status IN ('Pending Approval', 'Approved') THEN pad.amount ELSE 0 END), 0) AS reservedSoFar
        FROM dbo.payment_allocation_details pad
        JOIN dbo.payment_info pyi ON pyi.payment_sno = pad.payment_sno
        WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno
    ) paid
    CROSS APPLY dbo.fn_nt_BillPayable(iad.invoice_alloc_sno) bp
    WHERE iad.is_active = 'Y' AND iad.release_amount > paid.paidSoFar + paid.reservedSoFar + 0.01
      AND (@vendor_sno IS NULL OR i.vendor_sno = @vendor_sno)
    ORDER BY i.invoice_date, iad.invoice_alloc_sno;
END
GO

-- ── 5. what can be adjusted against a payment ───────────────────────────────
-- Same recordsets as before; the advances are now only those that may be used on the bills being paid: the ones paid against
-- their PO (scope OWN) and, once a PO is cancelled / closed, its leftover advance on the supplier's other bills (scope SUPPLIER).
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentAdjustments
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @v INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @bills NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.invoice_snos');
    SELECT advance_sno, advance_no, po_basic_sno, po_no, paid_date, amount, balance, scope
    FROM dbo.fn_nt_PaymentAdvancesForBills(@v, @bills) ORDER BY CASE scope WHEN 'OWN' THEN 0 ELSE 1 END, paid_date, advance_sno;

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

-- ── 6. Save a payment - or let the approver pay less now ────────────────────
-- @jsonInput: { vendor_sno, payment_date, mode, bank_account?, reference_no?, remarks?, created_by, preview?, apply_tds?,
--   allocations: [{ invoice_alloc_sno, amount }], advances: [{ advance_sno, amount }], notes: [{ type: 'DEBIT'|'CREDIT', note_sno }] }
--
-- A bill may be paid in part: amount can be anything from 0.01 up to what can be paid on it now (fn_nt_BillPayable.payable_now - less
-- than the outstanding while the GST waits for GSTR-2B).  The rest stays on the bill for another payment.
--
-- Revise (the approver pays less now):  { revise_payment_sno, revised_by, reason, allocations: [{ invoice_sno, amount }] }
--   each listed invoice is cut down to `amount` (0 = leave that invoice out of this payment; never more than saved); invoices not
--   listed stay as they are.  TDS is worked out again on the new amounts, advances are trimmed to what is still payable (the
--   rest goes back to the advance), notes stay.  The payment keeps its number, status and place in the approval chain.
--
-- TDS base is taxable-first: payments on a bill cover its taxable value first and its GST after, so TDS is taken on the taxable
-- value only and never twice on the same rupee.
CREATE OR ALTER PROCEDURE dbo.sp_nt_ReleasePaymentNet
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @rev INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.revise_payment_sno') AS INT),
            @revBy VARCHAR(30) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.revised_by'))), ''),
            @revReason NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.reason'))), ''),
            @v INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @pdate DATE = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_date') AS DATE), CAST(GETDATE() AS DATE)),
            @mode VARCHAR(10) = JSON_VALUE(@jsonInput, '$.mode'), @bank VARCHAR(100) = JSON_VALUE(@jsonInput, '$.bank_account'),
            @ref VARCHAR(100) = JSON_VALUE(@jsonInput, '$.reference_no'), @rem VARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks'),
            @by VARCHAR(20) = JSON_VALUE(@jsonInput, '$.created_by'),
            @preview BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.preview') IN ('1', 'true') THEN 1 ELSE 0 END,
            @applyTds BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.apply_tds') IN ('0', 'false') THEN 0 ELSE 1 END,
            @allocJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.allocations'),
            @advJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.advances'),
            @noteJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.notes'),
            @tdsJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.tds_overrides');
    DECLARE @own_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END, @in_tran BIT = 0;

    IF @rev IS NULL AND (@v IS NULL OR @mode IS NULL OR @by IS NULL OR @allocJson IS NULL) THROW 55011, 'vendor_sno, mode, created_by and allocations are required.', 1;
    IF @rev IS NOT NULL AND (@revBy IS NULL OR @allocJson IS NULL) THROW 55011, 'revised_by and allocations are required to change a payment.', 1;
    IF @rev IS NOT NULL SET @preview = 0;

    DECLARE @alloc TABLE (invoice_alloc_sno INT, amount DECIMAL(18,2));
    DECLARE @adv TABLE (advance_sno INT, amount DECIMAL(18,2));
    DECLARE @notes TABLE (note_type VARCHAR(6), note_sno INT, amount DECIMAL(18,2), note_no VARCHAR(60));
    DECLARE @old TABLE (invoice_alloc_sno INT, invoice_sno INT, amount DECIMAL(18,2));
    DECLARE @want TABLE (invoice_sno INT, amount DECIMAL(18,2));
    DECLARE @inv TABLE (invoice_sno INT PRIMARY KEY, gross DECIMAL(18,2), base DECIMAL(18,2), section VARCHAR(10),
                        taxable DECIMAL(18,2) NULL, rate DECIMAL(6,3) NULL, tds DECIMAL(18,2) NOT NULL DEFAULT 0, fy INT NULL);
    DECLARE @psno INT, @pno VARCHAR(30), @oldNet DECIMAL(18,2), @oldGross DECIMAL(18,2);

    BEGIN TRY
        IF @preview = 0
        BEGIN
            IF @own_tran = 1 BEGIN TRANSACTION; ELSE SAVE TRANSACTION pay_release_net;
            SET @in_tran = 1;
        END

        IF @rev IS NOT NULL
        BEGIN
            SELECT @v = vendor_sno FROM dbo.payment_info WHERE payment_sno = @rev AND is_active = 'Y';
            IF @v IS NULL THROW 55030, N'Payment not found.', 1;
        END

        -- one save per supplier at a time: the checks below cannot race another payment for the same bill / note / advance
        IF @in_tran = 1
        BEGIN
            DECLARE @lockName NVARCHAR(100) = N'pay_release_vendor_' + CAST(@v AS NVARCHAR(12)), @lk INT;
            EXEC @lk = sp_getapplock @Resource = @lockName, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
            IF @lk < 0 THROW 55023, 'Another payment for this supplier is being saved right now - please try again in a moment.', 1;
        END

        IF @rev IS NOT NULL
        BEGIN
            DECLARE @pst VARCHAR(20), @ptype VARCHAR(10);
            SELECT @pst = status, @ptype = payment_type, @mode = mode, @bank = bank_account, @ref = reference_no, @rem = remarks, @pdate = payment_date,
                   @pno = payment_no, @psno = payment_sno, @oldNet = ISNULL(net_paid, amount), @oldGross = ISNULL(gross_amount, amount)
            FROM dbo.payment_info WITH (UPDLOCK) WHERE payment_sno = @rev AND is_active = 'Y';
            IF @pst <> 'Pending Approval' THROW 55031, N'Only a payment that is awaiting approval can be changed.', 1;
            IF ISNULL(@ptype, 'BILL') <> 'BILL' THROW 55031, N'An advance payment has no invoices to reduce.', 1;
            IF @revReason IS NULL THROW 55033, N'Give the reason for paying less now.', 1;

            INSERT INTO @old SELECT pad.invoice_alloc_sno, iad.invoice_sno, pad.amount
            FROM dbo.payment_allocation_details pad JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = pad.invoice_alloc_sno
            WHERE pad.payment_sno = @rev;
            IF NOT EXISTS (SELECT 1 FROM @old) THROW 55031, N'This payment has no invoices.', 1;

            INSERT INTO @want
            SELECT TRY_CAST(JSON_VALUE(value, '$.invoice_sno') AS INT), SUM(TRY_CAST(JSON_VALUE(value, '$.amount') AS DECIMAL(18,2)))
            FROM OPENJSON(@allocJson) GROUP BY TRY_CAST(JSON_VALUE(value, '$.invoice_sno') AS INT);
            IF EXISTS (SELECT 1 FROM @want w WHERE w.invoice_sno IS NULL OR w.amount IS NULL OR w.amount < 0
                       OR NOT EXISTS (SELECT 1 FROM @old o WHERE o.invoice_sno = w.invoice_sno))
                THROW 55032, N'Each line needs an invoice of this payment and an amount of zero or more.', 1;
            IF EXISTS (SELECT 1 FROM @want w JOIN (SELECT invoice_sno, SUM(amount) AS total FROM @old GROUP BY invoice_sno) t ON t.invoice_sno = w.invoice_sno
                       WHERE w.amount > t.total + 0.005)
                THROW 55032, N'An amount cannot be raised above what the payment was saved for - only reduced.', 1;

            -- cut each listed invoice down, spread over its bills pro rata; the rounding difference goes on the biggest bill
            INSERT INTO @alloc (invoice_alloc_sno, amount)
            SELECT o.invoice_alloc_sno, CASE WHEN w.invoice_sno IS NULL THEN o.amount ELSE ROUND(o.amount * w.amount / t.total, 2) END
            FROM @old o
            JOIN (SELECT invoice_sno, SUM(amount) AS total FROM @old GROUP BY invoice_sno) t ON t.invoice_sno = o.invoice_sno
            LEFT JOIN @want w ON w.invoice_sno = o.invoice_sno;
            ;WITH d AS (
                SELECT a.invoice_alloc_sno, w.amount - SUM(a.amount) OVER (PARTITION BY o.invoice_sno) AS diff,
                       ROW_NUMBER() OVER (PARTITION BY o.invoice_sno ORDER BY a.amount DESC, a.invoice_alloc_sno) AS rn
                FROM @alloc a JOIN @old o ON o.invoice_alloc_sno = a.invoice_alloc_sno JOIN @want w ON w.invoice_sno = o.invoice_sno
            )
            UPDATE a SET amount = a.amount + d.diff FROM @alloc a JOIN d ON d.invoice_alloc_sno = a.invoice_alloc_sno WHERE d.rn = 1;
            DELETE FROM @alloc WHERE amount <= 0;
            IF NOT EXISTS (SELECT 1 FROM @alloc) THROW 55032, N'Not every invoice can be taken out - reject or cancel the payment instead.', 1;
            IF NOT EXISTS (SELECT 1 FROM @old o LEFT JOIN @alloc a ON a.invoice_alloc_sno = o.invoice_alloc_sno WHERE ISNULL(a.amount, 0) < o.amount - 0.005)
                THROW 55032, N'Nothing was reduced.', 1;

            -- what the payment carries over: advances, notes, whether TDS was on
            INSERT INTO @adv SELECT ref_sno, amount FROM dbo.payment_adjustment WHERE payment_sno = @rev AND adj_type = 'ADVANCE';
            INSERT INTO @notes (note_type, note_sno, amount)
            SELECT CASE adj_type WHEN 'DEBIT_NOTE' THEN 'DEBIT' ELSE 'CREDIT' END, ref_sno, amount
            FROM dbo.payment_adjustment WHERE payment_sno = @rev AND adj_type IN ('DEBIT_NOTE', 'CREDIT_NOTE');
            SET @applyTds = CASE WHEN EXISTS (SELECT 1 FROM dbo.tds_deduction WHERE payment_sno = @rev) THEN 1 ELSE 0 END;
            SET @tdsJson = NULL;   -- the sections chosen when it was saved stay on the invoices

            -- give back what the payment held, so every check below sees the bills / advances as they are without it
            UPDATE s SET adjusted_amount = s.adjusted_amount - a.amount FROM dbo.nt_supplier_advance_payment s JOIN @adv a ON a.advance_sno = s.advance_sno;
            DELETE FROM dbo.payment_adjustment WHERE payment_sno = @rev;
            DELETE FROM dbo.tds_deduction WHERE payment_sno = @rev;
            DELETE FROM dbo.payment_allocation_details WHERE payment_sno = @rev;
            SET @by = LEFT(@revBy, 20);
        END
        ELSE
        BEGIN
            INSERT INTO @alloc SELECT TRY_CAST(JSON_VALUE(value, '$.invoice_alloc_sno') AS INT), TRY_CAST(JSON_VALUE(value, '$.amount') AS DECIMAL(18,2)) FROM OPENJSON(@allocJson);
            IF @advJson IS NOT NULL
                INSERT INTO @adv SELECT TRY_CAST(JSON_VALUE(value, '$.advance_sno') AS INT), TRY_CAST(JSON_VALUE(value, '$.amount') AS DECIMAL(18,2)) FROM OPENJSON(@advJson);
            IF @noteJson IS NOT NULL
                INSERT INTO @notes (note_type, note_sno) SELECT DISTINCT UPPER(JSON_VALUE(value, '$.type')), TRY_CAST(JSON_VALUE(value, '$.note_sno') AS INT) FROM OPENJSON(@noteJson);
        END

        -- ── the bills ───────────────────────────────────────────────────────
        IF NOT EXISTS (SELECT 1 FROM @alloc) OR EXISTS (SELECT 1 FROM @alloc WHERE invoice_alloc_sno IS NULL OR amount IS NULL OR amount <= 0)
            THROW 55012, 'Each allocation needs an invoice_alloc_sno and a positive amount.', 1;
        IF EXISTS (SELECT 1 FROM (SELECT invoice_alloc_sno FROM @alloc GROUP BY invoice_alloc_sno HAVING COUNT(*) > 1) x)
            THROW 55012, 'A bill is listed twice in the payment.', 1;

        -- every bill must belong to this supplier and still have that much unpaid release amount (a saved / approved payment has already reserved its share)
        IF EXISTS (
            SELECT 1 FROM @alloc a
            LEFT JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = a.invoice_alloc_sno AND iad.is_active = 'Y'
            LEFT JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
            OUTER APPLY dbo.fn_nt_BillPayable(a.invoice_alloc_sno) bp
            WHERE iad.invoice_alloc_sno IS NULL OR i.vendor_sno <> @v OR a.amount > bp.outstanding + 0.01
        )
            THROW 55013, 'An allocation is unknown, belongs to another supplier, or exceeds its unpaid release amount.', 1;

        -- GSTR-2B hold: until the invoice shows in 2B (or Accounts releases the hold) only its taxable part may be paid
        IF EXISTS (SELECT 1 FROM @alloc a CROSS APPLY dbo.fn_nt_BillPayable(a.invoice_alloc_sno) bp WHERE a.amount > bp.payable_now + 0.01)
        BEGIN
            DECLARE @heldMsg NVARCHAR(900) = (
                SELECT N'Payment held until the invoice appears in GSTR-2B (or Accounts releases the hold) - ' + STRING_AGG(
                       inv.invoice_no + CASE WHEN bp.taxable_known = 1 THEN N': only ' + FORMAT(bp.payable_now, 'N2') + N' can be paid now, the GST part ' + FORMAT(bp.hold_2b, 'N2') + N' follows after 2B'
                                             ELSE N': nothing can be paid before 2B (no taxable value on the invoice to split it)' END, N'; ')
                FROM @alloc a CROSS APPLY dbo.fn_nt_BillPayable(a.invoice_alloc_sno) bp
                JOIN dbo.invoice_info inv ON inv.invoice_sno = bp.invoice_sno
                WHERE a.amount > bp.payable_now + 0.01);
            THROW 55021, @heldMsg, 1;
        END

        -- per-invoice figures. TDS base is taxable-first: min(paid + this, taxable part) - min(paid, taxable part)
        INSERT INTO @inv (invoice_sno, gross, base, section)
        SELECT i.invoice_sno, SUM(a.amount),
               ROUND(SUM(CASE WHEN bp.settled + bp.reserved + a.amount < bp.taxable_part THEN bp.settled + bp.reserved + a.amount ELSE bp.taxable_part END
                        - CASE WHEN bp.settled + bp.reserved < bp.taxable_part THEN bp.settled + bp.reserved ELSE bp.taxable_part END), 2),
               i.tds_section_code
        FROM @alloc a
        JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = a.invoice_alloc_sno
        JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
        CROSS APPLY dbo.fn_nt_BillPayable(a.invoice_alloc_sno) bp
        GROUP BY i.invoice_sno, i.tds_section_code;

        DECLARE @gross DECIMAL(18,2) = (SELECT SUM(amount) FROM @alloc);

        -- optional per-invoice TDS section chosen on the payment screen: tds_overrides [{ invoice_sno, section }] ('' = no TDS)
        IF @tdsJson IS NOT NULL
            UPDATE x SET section = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(o.value, '$.section')))), '')
            FROM @inv x JOIN OPENJSON(@tdsJson) o ON x.invoice_sno = TRY_CAST(JSON_VALUE(o.value, '$.invoice_sno') AS INT);

        IF @applyTds = 1
        BEGIN
            DECLARE @isno INT, @ibase DECIMAL(18,2), @isec VARCHAR(10), @t DECIMAL(18,2), @r DECIMAL(6,3), @tx DECIMAL(18,2), @fy INT;
            DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT invoice_sno, base, section FROM @inv WHERE section IS NOT NULL ORDER BY invoice_sno;
            OPEN cur; FETCH NEXT FROM cur INTO @isno, @ibase, @isec;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                DECLARE @xp DECIMAL(18,2) = ISNULL((SELECT SUM(base) FROM @inv WHERE section = @isec AND taxable IS NOT NULL), 0),
                        @xd DECIMAL(18,2) = ISNULL((SELECT SUM(taxable) FROM @inv WHERE section = @isec AND taxable IS NOT NULL), 0);
                EXEC dbo.sp_nt_CalcTDS @vendor_sno = @v, @section = @isec, @base = @ibase, @on_date = @pdate,
                     @extra_prior = @xp, @extra_deducted = @xd, @tds = @t OUTPUT, @rate = @r OUTPUT, @taxable = @tx OUTPUT, @fy = @fy OUTPUT;
                UPDATE @inv SET taxable = @tx, rate = @r, tds = @t, fy = @fy WHERE invoice_sno = @isno;
                FETCH NEXT FROM cur INTO @isno, @ibase, @isec;
            END
            CLOSE cur; DEALLOCATE cur;
        END
        DECLARE @tds DECIMAL(18,2) = ISNULL((SELECT SUM(tds) FROM @inv), 0);
        DECLARE @invJson NVARCHAR(MAX) = (SELECT '[' + STRING_AGG(CAST(invoice_sno AS VARCHAR(12)), ',') + ']' FROM @inv);

        -- ── advances ────────────────────────────────────────────────────────
        IF EXISTS (SELECT 1 FROM @adv a LEFT JOIN dbo.nt_supplier_advance_payment s ON s.advance_sno = a.advance_sno AND s.vendor_sno = @v AND s.is_active = 'Y'
                   WHERE a.amount IS NULL OR a.amount <= 0 OR s.advance_sno IS NULL OR a.amount > s.amount - s.adjusted_amount + 0.01)
            THROW 55014, 'An advance is unknown, belongs to another supplier, or the amount exceeds its balance.', 1;
        -- an advance belongs to its PO's invoices; it goes to the supplier's other invoices only when that PO is not going forward
        IF @rev IS NULL AND EXISTS (SELECT 1 FROM @adv a WHERE NOT EXISTS (SELECT 1 FROM dbo.fn_nt_PaymentAdvancesForBills(@v, @invJson) f WHERE f.advance_sno = a.advance_sno))
        BEGIN
            DECLARE @advMsg NVARCHAR(500) = N'An advance is kept for the invoices of the PO it was paid against - it can be used on other invoices only once that PO is cancelled or fully settled: '
                + (SELECT STRING_AGG(s.advance_no, ', ') FROM @adv a JOIN dbo.nt_supplier_advance_payment s ON s.advance_sno = a.advance_sno
                   WHERE NOT EXISTS (SELECT 1 FROM dbo.fn_nt_PaymentAdvancesForBills(@v, @invJson) f WHERE f.advance_sno = a.advance_sno));
            THROW 55025, @advMsg, 1;
        END
        -- a payment that was cut down uses less advance: trim it (newest advance first) to what is still payable; the rest stays on the advance
        IF @rev IS NOT NULL AND (SELECT ISNULL(SUM(amount), 0) FROM @adv) > @gross - @tds
        BEGIN
            DECLARE @excess DECIMAL(18,2) = (SELECT SUM(amount) FROM @adv) - (@gross - @tds), @asno INT, @aamt DECIMAL(18,2), @cut DECIMAL(18,2);
            DECLARE acur CURSOR LOCAL FAST_FORWARD FOR SELECT advance_sno, amount FROM @adv ORDER BY advance_sno DESC;
            OPEN acur; FETCH NEXT FROM acur INTO @asno, @aamt;
            WHILE @@FETCH_STATUS = 0 AND @excess > 0
            BEGIN
                SET @cut = CASE WHEN @aamt < @excess THEN @aamt ELSE @excess END;
                UPDATE @adv SET amount = amount - @cut WHERE advance_sno = @asno;
                SET @excess = @excess - @cut;
                FETCH NEXT FROM acur INTO @asno, @aamt;
            END
            CLOSE acur; DEALLOCATE acur;
            DELETE FROM @adv WHERE amount <= 0;
        END
        DECLARE @advTotal DECIMAL(18,2) = ISNULL((SELECT SUM(amount) FROM @adv), 0);
        IF @advTotal > @gross - @tds + 0.01 THROW 55015, 'Advance adjusted cannot exceed the amount payable after TDS.', 1;

        -- ── notes (sql/64: only notes offered for the bills being paid; a note already redeemed elsewhere is named) ──
        IF EXISTS (SELECT 1 FROM @notes WHERE note_type NOT IN ('DEBIT', 'CREDIT') OR note_sno IS NULL) THROW 55016, 'Each note needs type DEBIT or CREDIT and a note_sno.', 1;
        UPDATE n SET amount = d.total_amount, note_no = d.debit_note_no FROM @notes n JOIN dbo.debit_note_basic_info d ON d.debit_note_sno = n.note_sno AND d.vendor_sno = @v AND d.is_active = 'Y'
            WHERE n.note_type = 'DEBIT';
        UPDATE n SET amount = c.total_amount, note_no = c.credit_note_no FROM @notes n JOIN dbo.credit_note_basic_info c ON c.credit_note_sno = n.note_sno AND c.vendor_sno = @v AND c.is_active = 'Y'
            WHERE n.note_type = 'CREDIT';
        IF EXISTS (SELECT 1 FROM @notes WHERE amount IS NULL) THROW 55017, 'A note is unknown, belongs to another supplier, or is no longer active.', 1;

        DECLARE @gone NVARCHAR(400) = (SELECT STRING_AGG(n.note_no + ' (' + ISNULL(pi.payment_no, 'another payment') + ')', ', ')
            FROM @notes n JOIN dbo.payment_adjustment pa ON pa.adj_type = CASE n.note_type WHEN 'DEBIT' THEN 'DEBIT_NOTE' ELSE 'CREDIT_NOTE' END AND pa.ref_sno = n.note_sno
            LEFT JOIN dbo.payment_info pi ON pi.payment_sno = pa.payment_sno);
        IF @gone IS NOT NULL
        BEGIN
            DECLARE @goneMsg NVARCHAR(500) = N'Already redeemed in another payment - refresh and untick it: ' + @gone;
            THROW 55024, @goneMsg, 1;
        END

        IF @rev IS NULL
        BEGIN
            DECLARE @offered TABLE (note_type VARCHAR(6), note_sno INT);
            INSERT INTO @offered SELECT note_type, note_sno FROM dbo.fn_nt_PaymentNotesForBills(@v, @invJson);
            IF EXISTS (SELECT 1 FROM @notes n WHERE NOT EXISTS (SELECT 1 FROM @offered o WHERE o.note_type = n.note_type AND o.note_sno = n.note_sno))
            BEGIN
                DECLARE @off NVARCHAR(400) = (SELECT STRING_AGG(n.note_no, ', ') FROM @notes n WHERE NOT EXISTS (SELECT 1 FROM @offered o WHERE o.note_type = n.note_type AND o.note_sno = n.note_sno));
                DECLARE @offMsg NVARCHAR(500) = N'Not available for the invoices being paid (its own bill is still open, or it belongs to another company): ' + @off;
                THROW 55022, @offMsg, 1;
            END
        END

        DECLARE @dn DECIMAL(18,2) = ISNULL((SELECT SUM(amount) FROM @notes WHERE note_type = 'DEBIT'), 0),
                @cn DECIMAL(18,2) = ISNULL((SELECT SUM(amount) FROM @notes WHERE note_type = 'CREDIT'), 0);

        DECLARE @net DECIMAL(18,2) = @gross - @tds - @advTotal - @dn + @cn;
        IF @net < 0 THROW 55018, 'Debit notes and advances exceed what is payable - nothing to pay.', 1;

        IF @preview = 1
        BEGIN
            SELECT @gross AS gross_amount, @tds AS tds_amount, @advTotal AS advance_adjusted, @dn AS debit_notes, @cn AS credit_notes, @net AS net_paid;
            SELECT i.invoice_sno, inv.invoice_no, i.gross, i.base AS taxable_base, i.section AS tds_section, i.rate AS tds_rate_pct, i.taxable AS tds_taxable, i.tds AS tds_amount,
                   b.payable_total, b.paid_before, CAST(b.payable_total - b.paid_before - i.gross AS DECIMAL(18,2)) AS balance_after,
                   CAST(CASE WHEN b.paid_before > 0 OR b.payable_total - b.paid_before - i.gross > 0.01 THEN 1 ELSE 0 END AS BIT) AS is_part,
                   inv.vendor_invoice_no AS supplier_invoice_no
            FROM @inv i JOIN dbo.invoice_info inv ON inv.invoice_sno = i.invoice_sno
            CROSS APPLY (SELECT SUM(bp.release_amount) AS payable_total, SUM(bp.settled + bp.reserved) AS paid_before
                         FROM dbo.invoice_allocation_details iad CROSS APPLY dbo.fn_nt_BillPayable(iad.invoice_alloc_sno) bp
                         WHERE iad.invoice_sno = i.invoice_sno AND iad.is_active = 'Y') b;
            RETURN;
        END

        -- ── write ───────────────────────────────────────────────────────────
        IF @rev IS NULL
        BEGIN
            -- org of the payment: the invoice's own, else its PO's (some invoices carry no company) - the approval workflow is looked up on it
            DECLARE @com INT, @div INT, @brn INT, @dept INT;
            SELECT TOP 1 @com  = IIF(i.com_sno IS NULL, p.com_sno,  i.com_sno),  @div  = IIF(i.com_sno IS NULL, p.div_sno,  i.div_sno),
                         @brn  = IIF(i.com_sno IS NULL, p.brn_sno,  i.brn_sno),  @dept = IIF(i.com_sno IS NULL, p.dept_sno, i.dept_sno)
            FROM @inv x JOIN dbo.invoice_info i ON i.invoice_sno = x.invoice_sno
            LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
            ORDER BY x.invoice_sno;

            DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
            SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(payment_no, 6) AS INT)), 0) + 1 FROM dbo.payment_info WITH (UPDLOCK, HOLDLOCK) WHERE payment_no LIKE 'PAY-' + @year + '-%';
            SET @pno = 'PAY-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

            INSERT INTO dbo.payment_info (payment_no, vendor_sno, payment_date, amount, mode, bank_account, reference_no, status, remarks, is_active, created_by, created_date,
                                          gross_amount, tds_amount, advance_adjusted, note_adjusted, net_paid, com_sno, div_sno, brn_sno, dept_sno)
            VALUES (@pno, @v, @pdate, @gross, @mode, @bank, @ref, 'Pending Approval', @rem, 'Y', @by, GETDATE(),
                    @gross, @tds, @advTotal, @dn - @cn, @net, @com, @div, @brn, @dept);
            SET @psno = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE dbo.payment_info SET amount = @gross, gross_amount = @gross, tds_amount = @tds, advance_adjusted = @advTotal, note_adjusted = @dn - @cn,
                   net_paid = @net, modified_by = @by, modified_date = GETDATE()
            WHERE payment_sno = @psno;
        END

        INSERT INTO dbo.payment_allocation_details (payment_sno, invoice_alloc_sno, amount, created_date) SELECT @psno, invoice_alloc_sno, amount, GETDATE() FROM @alloc;
        IF @tdsJson IS NOT NULL   -- remember the chosen section on the invoice for its later part-payments
            UPDATE inv SET tds_section_code = x.section FROM dbo.invoice_info inv JOIN @inv x ON x.invoice_sno = inv.invoice_sno;

        -- TDS: track every payment base (even when TDS = 0) so annual thresholds work
        INSERT INTO dbo.tds_deduction (vendor_sno, section_code, fin_year, invoice_sno, payment_sno, base_amount, base_deducted, rate_pct, tds_amount)
        SELECT @v, section, fy, invoice_sno, @psno, base, ISNULL(taxable, 0), ISNULL(rate, 0), tds FROM @inv WHERE section IS NOT NULL AND fy IS NOT NULL;
        INSERT INTO dbo.payment_adjustment (payment_sno, adj_type, ref_sno, invoice_sno, amount) SELECT @psno, 'TDS', NULL, invoice_sno, tds FROM @inv WHERE tds > 0;

        INSERT INTO dbo.payment_adjustment (payment_sno, adj_type, ref_sno, amount) SELECT @psno, 'ADVANCE', advance_sno, amount FROM @adv;
        UPDATE s SET adjusted_amount = s.adjusted_amount + a.amount FROM dbo.nt_supplier_advance_payment s JOIN @adv a ON a.advance_sno = s.advance_sno;
        INSERT INTO dbo.payment_adjustment (payment_sno, adj_type, ref_sno, amount) SELECT @psno, CASE note_type WHEN 'DEBIT' THEN 'DEBIT_NOTE' ELSE 'CREDIT_NOTE' END, note_sno, amount FROM @notes;

        IF @rev IS NULL
        BEGIN
            DECLARE @sub NVARCHAR(200) = (SELECT @psno AS payment_sno, @by AS created_by FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            EXEC dbo.sp_nt_SubmitPaymentForApproval @jsonInput = @sub, @silent = 1;
        END
        ELSE
        BEGIN
            DECLARE @hist NVARCHAR(500) = LEFT(N'Paying less now (' + FORMAT(@oldGross, 'N2') + N' -> ' + FORMAT(@gross, 'N2') + N'; net ' + FORMAT(@oldNet, 'N2') + N' -> ' + FORMAT(@net, 'N2')
                + N'): ' + @revReason, 500);
            INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment) VALUES (@psno, 'REVISED', @by, @hist);
        END

        IF @own_tran = 1 COMMIT TRANSACTION;
        SELECT p.payment_sno, p.payment_no, @gross AS gross_amount, @tds AS tds_amount, @advTotal AS advance_adjusted,
               @dn AS debit_notes, @cn AS credit_notes, @net AS net_paid, CAST(NULL AS INT) AS journal_sno, 'SUCCESS' AS result,
               p.com_sno, p.div_sno, p.brn_sno, p.dept_sno,
               p.status, p.current_approver_id, p.created_by, CAST(CASE WHEN p.status = 'Approved' THEN 1 ELSE 0 END AS BIT) AS is_final
        FROM dbo.payment_info p WHERE p.payment_sno = @psno;
    END TRY
    BEGIN CATCH
        IF @in_tran = 1 AND @own_tran = 1
        BEGIN
            IF XACT_STATE() <> 0 ROLLBACK TRAN;
        END
        ELSE IF @in_tran = 1 AND XACT_STATE() = 1
        BEGIN
            ROLLBACK TRAN pay_release_net;      -- undo only our own writes; the caller decides the rest
        END;
        THROW;
    END CATCH
END
GO

-- ── 6b. the approver pays less now ──────────────────────────────────────────
-- @jsonInput: { payment_sno, revised_by, reason, allocations: [{ invoice_sno, amount }] }
-- Only the approver the payment is with now may do it (or this stage's alternate, once the stage has waited past its escalation time -
-- the same rule as approving).  The work is sp_nt_ReleasePaymentNet's revise mode.
CREATE OR ALTER PROCEDURE dbo.sp_nt_RevisePayment
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT),
            @by VARCHAR(30) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.revised_by'))), '');
    IF @pay IS NULL THROW 56001, N'Payment not found.', 1;
    IF @by IS NULL THROW 56003, N'The approver is required.', 1;

    DECLARE @status VARCHAR(20), @cur_appr VARCHAR(30), @stages NVARCHAR(MAX), @cur INT, @since DATETIME, @stage NVARCHAR(MAX), @esc INT, @ok BIT = 0;
    SELECT @status = status, @cur_appr = current_approver_id FROM dbo.payment_info WHERE payment_sno = @pay AND is_active = 'Y';
    IF @status IS NULL THROW 56001, N'Payment not found.', 1;
    IF @status <> 'Pending Approval' THROW 56002, N'This payment is not awaiting approval.', 1;

    IF @by = @cur_appr SET @ok = 1;
    ELSE
    BEGIN
        SELECT @stages = stages_json, @cur = current_seq, @since = current_since
        FROM dbo.approval_instance WHERE entity_type = 'Payment' AND entity_ref_id = @pay AND status = 'P';
        IF @stages IS NOT NULL AND @cur IS NOT NULL
        BEGIN
            SET @stage = (SELECT s.value FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@cur AS NVARCHAR(10)));
            SET @esc = ISNULL(TRY_CAST(JSON_VALUE(@stage, '$.escalation_hours') AS INT), 24);
            IF EXISTS (SELECT 1 FROM OPENJSON(@stage, '$.alternates') a WHERE a.value COLLATE DATABASE_DEFAULT = @by)
               AND DATEDIFF(MINUTE, @since, GETDATE()) >= @esc * 60
                SET @ok = 1;
        END
    END
    IF @ok = 0 THROW 56003, N'Only the approver this payment is with can pay less now.', 1;

    DECLARE @j NVARCHAR(MAX) = (SELECT @pay AS revise_payment_sno, @by AS revised_by, JSON_VALUE(@jsonInput, '$.reason') AS reason,
                                       JSON_QUERY(@jsonInput, '$.allocations') AS allocations FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC dbo.sp_nt_ReleasePaymentNet @jsonInput = @j;
END
GO

-- ── 6c. one payment's invoices with the figures an approver needs to decide how much to pay now ──
-- @jsonInput: { payment_sno } -> per invoice: what the invoice is, what it may be paid in all, what OTHER payments hold or have paid,
-- what this payment pays, what is left after it, and the GST that waits for GSTR-2B.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentInvoiceFigures
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT);
    DECLARE @own BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.payment_info WHERE payment_sno = @pay AND status NOT IN ('Rejected', 'Cancelled')) THEN 1 ELSE 0 END;
    SELECT l.invoice_sno, l.invoice_no, l.supplier_invoice_no, i.invoice_amount,
           CAST(CASE WHEN i.taxable_value IS NOT NULL AND i.invoice_amount > 0 AND i.taxable_value <= i.invoice_amount THEN i.invoice_amount - i.taxable_value END AS DECIMAL(18,2)) AS gst_amount,
           t.payable_total, CAST(t.paid_all - CASE WHEN @own = 1 THEN l.amount ELSE 0 END AS DECIMAL(18,2)) AS paid_other,
           l.amount AS this_amount,
           CAST(t.payable_total - (t.paid_all - CASE WHEN @own = 1 THEN l.amount ELSE 0 END) - l.amount AS DECIMAL(18,2)) AS balance_after,
           CAST(t.on_hold_2b AS BIT) AS on_hold_2b, t.hold_2b
    FROM dbo.fn_nt_PaymentLines(@pay) l
    JOIN dbo.invoice_info i ON i.invoice_sno = l.invoice_sno
    CROSS APPLY (
        SELECT SUM(bp.release_amount) AS payable_total, SUM(bp.settled + bp.reserved) AS paid_all,
               MAX(CAST(bp.on_hold_2b AS INT)) AS on_hold_2b, SUM(bp.hold_2b) AS hold_2b
        FROM dbo.invoice_allocation_details a CROSS APPLY dbo.fn_nt_BillPayable(a.invoice_alloc_sno) bp
        WHERE a.invoice_sno = l.invoice_sno AND a.is_active = 'Y'
    ) t
    ORDER BY l.invoice_sno;
END
GO

-- ── 7. note scope: notes of a cancelled PO's invoices become the supplier's ──
-- ── 3. "paid" means settled: a saved / approved payment only reserves its bills ──
-- Same as sql/64 except `paid` counts only payments that are not Pending Approval / Approved (Rejected / Cancelled hold no
-- allocations), so a bill is "closed" - and its notes become supplier-wide - only once the money has actually gone.
CREATE OR ALTER FUNCTION dbo.fn_nt_PaymentNoteScope (@vendor_sno INT)
RETURNS TABLE
AS
RETURN
(
    WITH n AS (
        SELECT CAST('DEBIT' AS VARCHAR(6)) AS note_type, d.debit_note_sno AS note_sno, d.debit_note_no AS note_no,
               d.po_basic_sno, d.grn_basic_sno, d.com_sno, d.debit_note_date AS note_date, d.total_amount AS amount, d.remarks
        FROM dbo.debit_note_basic_info d
        WHERE d.vendor_sno = @vendor_sno AND d.is_active = 'Y' AND ISNULL(d.total_amount, 0) > 0
          AND NOT EXISTS (SELECT 1 FROM dbo.payment_adjustment pa WHERE pa.adj_type = 'DEBIT_NOTE' AND pa.ref_sno = d.debit_note_sno)
        UNION ALL
        SELECT 'CREDIT', c.credit_note_sno, c.credit_note_no,
               c.po_basic_sno, c.grn_basic_sno, c.com_sno, c.credit_note_date, c.total_amount, c.remarks
        FROM dbo.credit_note_basic_info c
        WHERE c.vendor_sno = @vendor_sno AND c.is_active = 'Y' AND ISNULL(c.total_amount, 0) > 0
          AND NOT EXISTS (SELECT 1 FROM dbo.payment_adjustment pa WHERE pa.adj_type = 'CREDIT_NOTE' AND pa.ref_sno = c.credit_note_sno)
    ),
    inv AS (   -- the supplier's live invoices, and whether each is paid in full (settled payments only)
        SELECT i.invoice_sno, i.po_basic_sno,
               i.invoice_no + CASE WHEN NULLIF(LTRIM(RTRIM(i.vendor_invoice_no)), '') IS NULL THEN '' ELSE ' (' + LTRIM(RTRIM(i.vendor_invoice_no)) + ')' END AS invoice_label,
               CAST(CASE WHEN a.alloc_count > 0 AND a.paid_total > 0 AND a.release_total - a.paid_total <= 0.01 THEN 1 ELSE 0 END AS BIT) AS is_closed
        FROM dbo.invoice_info i
        LEFT JOIN dbo.po_request_info ipo ON ipo.po_basic_sno = i.po_basic_sno
        OUTER APPLY (
            SELECT COUNT(*) AS alloc_count, SUM(iad.release_amount) AS release_total, SUM(ISNULL(pd.paid, 0)) AS paid_total
            FROM dbo.invoice_allocation_details iad
            OUTER APPLY (SELECT SUM(pad.amount) AS paid
                         FROM dbo.payment_allocation_details pad
                         JOIN dbo.payment_info pyi ON pyi.payment_sno = pad.payment_sno AND pyi.status NOT IN ('Pending Approval', 'Approved', 'Rejected', 'Cancelled')
                         WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno) pd
            WHERE iad.invoice_sno = i.invoice_sno AND iad.is_active = 'Y'
        ) a
        WHERE i.vendor_sno = @vendor_sno AND i.is_active = 'Y'
          AND (ipo.po_basic_sno IS NULL OR (ipo.is_active = 'Y' AND ipo.status IN ('A', 'P')))   -- an invoice of a cancelled PO is not going forward (sql/70)
    ),
    line AS (  -- bills that allocate the same PO line(s) the note was raised on
        SELECT DISTINCT it.note_type, it.note_sno, iad.invoice_sno
        FROM (
            SELECT 'DEBIT' AS note_type, di.debit_note_sno AS note_sno, di.po_item_sno
            FROM dbo.debit_note_item_details di WHERE di.is_active = 'Y' AND di.po_item_sno IS NOT NULL
            UNION ALL
            SELECT 'CREDIT', ci.credit_note_sno, ci.po_item_sno
            FROM dbo.credit_note_item_details ci WHERE ci.is_active = 'Y' AND ci.po_item_sno IS NOT NULL
        ) it
        JOIN n ON n.note_type = it.note_type AND n.note_sno = it.note_sno
        JOIN dbo.invoice_allocation_details iad ON iad.po_item_sno = it.po_item_sno AND iad.is_active = 'Y'
        JOIN inv ON inv.invoice_sno = iad.invoice_sno
    ),
    src AS (
        SELECT l.note_type, l.note_sno, l.invoice_sno FROM line l
        UNION ALL   -- no bill allocates those lines: every live invoice on the note's PO
        SELECT n.note_type, n.note_sno, inv.invoice_sno
        FROM n JOIN inv ON inv.po_basic_sno = n.po_basic_sno
        WHERE NOT EXISTS (SELECT 1 FROM line l WHERE l.note_type = n.note_type AND l.note_sno = n.note_sno)
    )
    SELECT n.note_type, n.note_sno, n.note_no, n.po_basic_sno, n.grn_basic_sno, n.com_sno, n.note_date, n.amount, n.remarks,
           s.invoice_sno, inv.invoice_label, inv.is_closed
    FROM n
    LEFT JOIN src s ON s.note_type = n.note_type AND s.note_sno = n.note_sno
    LEFT JOIN inv ON inv.invoice_sno = s.invoice_sno
);
GO

-- ── 8. the run: no alert e-mail any more, per-invoice snapshot, gross / TDS / advance / notes on each item ──
-- ── 5. a run refuses a portal supplier's payment ──
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

        -- a supplier paid on their portal is paid there and then recorded (sp_nt_RecordPortalPayment, sql/69) - never put in a run or a file
        DECLARE @portal NVARCHAR(500) = (
            SELECT STRING_AGG(ISNULL(k.company_name, '?') + ' (' + pi.payment_no + ')', ', ')
            FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno
            JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pi.vendor_sno
            WHERE k.pay_via_portal = 'Y' AND ISNULL(pi.net_paid, pi.amount) > 0);
        IF @portal IS NOT NULL
        BEGIN
            DECLARE @portalMsg NVARCHAR(700) = N'Paid on the supplier''s portal, not in a run: ' + @portal + N'. Pay it there and record the transaction, or untick it.';
            THROW 56115, @portalMsg, 1;
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
                                            beneficiary_name, account_no, ifsc, bank_name, branch_name, invoice_nos, supplier_invoice_nos, msme_label, narration,
                                            gross_amount, tds_amount, advance_amount, note_amount)
        SELECT @bsno, pi.payment_sno, ROW_NUMBER() OVER (ORDER BY s.line_no), pi.vendor_sno, k.company_name, k.supp_code, k.email,
               ISNULL(pi.net_paid, pi.amount), pi.mode, pi.bank_account, ch.channel,
               CASE WHEN ch.channel = 'BANK' THEN bk.ac_holder_name END, CASE WHEN ch.channel = 'BANK' THEN CAST(bk.ac_number AS VARCHAR(40)) END,
               CASE WHEN ch.channel = 'BANK' THEN bk.ifsc END, CASE WHEN ch.channel = 'BANK' THEN bk.bank_name END, CASE WHEN ch.channel = 'BANK' THEN bk.bank_branch_name END,
               inv.invoice_nos, inv.supplier_invoice_nos,
               CASE WHEN ISNULL(k.is_msme_avail, 'N') = 'Y' OR NULLIF(LTRIM(RTRIM(k.msme_type)), '') IS NOT NULL THEN ISNULL(NULLIF(LTRIM(RTRIM(k.msme_type)), ''), 'MSME') END,
               LEFT(pi.payment_no + ISNULL(' ' + inv.first_supplier_invoice, ''), 60),
               ISNULL(pi.gross_amount, pi.amount), ISNULL(pi.tds_amount, 0), ISNULL(pi.advance_adjusted, 0), ISNULL(pi.note_adjusted, 0)
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

        -- what each payment paid on each invoice, frozen for the auditor / payment inputter (sql/70): paid before, this payment, balance left
        INSERT INTO dbo.payment_batch_item_invoice (batch_item_sno, batch_sno, payment_sno, invoice_sno, invoice_no, supplier_invoice_no, invoice_date, invoice_amount, gst_amount,
                                                    payable_total, paid_before, this_gross, tds_amount, balance_after, awaiting_2b, part_no, kind)
        SELECT q.batch_item_sno, @bsno, q.payment_sno, q.invoice_sno, q.invoice_no, q.supplier_invoice_no, q.invoice_date, q.invoice_amount, q.gst_amount,
               q.payable_total, q.paid_before, q.amount, q.tds, q.balance_after,
               CASE WHEN q.balance_after > 0.01 AND q.on_hold = 1 THEN 1 ELSE 0 END, q.prior_n + 1,
               CASE WHEN q.balance_after > 0.01 THEN 'PART' WHEN q.prior_n = 0 THEN 'FULL' ELSE 'FINAL' END
        FROM (
            SELECT bi.batch_item_sno, bi.payment_sno, l.invoice_sno, l.invoice_no, l.supplier_invoice_no, l.invoice_date, i.invoice_amount,
                   CASE WHEN i.taxable_value IS NOT NULL AND i.invoice_amount > 0 AND i.taxable_value <= i.invoice_amount THEN i.invoice_amount - i.taxable_value END AS gst_amount,
                   tot.payable_total, ISNULL(pr.paid_before, 0) AS paid_before, l.amount,
                   ISNULL(td.tds, 0) AS tds, ISNULL(pr.prior_n, 0) AS prior_n,
                   CAST(tot.payable_total - ISNULL(pr.paid_before, 0) - l.amount AS DECIMAL(18,2)) AS balance_after,
                   CASE WHEN EXISTS (SELECT 1 FROM dbo.invoice_allocation_details a3 CROSS APPLY dbo.fn_nt_BillPayable(a3.invoice_alloc_sno) bp
                                     WHERE a3.invoice_sno = l.invoice_sno AND a3.is_active = 'Y' AND bp.on_hold_2b = 1) THEN 1 ELSE 0 END AS on_hold
            FROM dbo.payment_batch_item bi
            CROSS APPLY dbo.fn_nt_PaymentLines(bi.payment_sno) l
            JOIN dbo.invoice_info i ON i.invoice_sno = l.invoice_sno
            CROSS APPLY (SELECT SUM(a2.release_amount) AS payable_total FROM dbo.invoice_allocation_details a2 WHERE a2.invoice_sno = l.invoice_sno AND a2.is_active = 'Y') tot
            OUTER APPLY (SELECT SUM(pad.amount) AS paid_before, COUNT(DISTINCT pad.payment_sno) AS prior_n
                         FROM dbo.payment_allocation_details pad
                         JOIN dbo.invoice_allocation_details a4 ON a4.invoice_alloc_sno = pad.invoice_alloc_sno
                         JOIN dbo.payment_info p2 ON p2.payment_sno = pad.payment_sno AND p2.status = 'Processed' AND p2.payment_sno < bi.payment_sno
                         WHERE a4.invoice_sno = l.invoice_sno) pr
            OUTER APPLY (SELECT SUM(d.tds_amount) AS tds FROM dbo.tds_deduction d WHERE d.payment_sno = bi.payment_sno AND d.invoice_sno = l.invoice_sno) td
            WHERE bi.batch_sno = @bsno
        ) q;

        -- journals: the same entries the release used to post
        DECLARE @jl TABLE (head_sno INT, debit DECIMAL(18,2), credit DECIMAL(18,2));
        DECLARE @p INT, @pn VARCHAR(30), @pv INT, @gross DECIMAL(18,2), @tds DECIMAL(18,2), @adv DECIMAL(18,2), @net DECIMAL(18,2), @dn DECIMAL(18,2), @cn DECIMAL(18,2),
                @jc INT, @jd INT, @jb INT, @jdp INT, @j INT;
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT payment_sno FROM @sel ORDER BY line_no;
        OPEN cur; FETCH NEXT FROM cur INTO @p;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @pn = payment_no, @pv = vendor_sno, @gross = ISNULL(gross_amount, amount), @tds = ISNULL(tds_amount, 0), @adv = ISNULL(advance_adjusted, 0),
                   @net = ISNULL(net_paid, amount), @jc = com_sno, @jd = div_sno, @jb = brn_sno, @jdp = dept_sno
            FROM dbo.payment_info WHERE payment_sno = @p;
            SELECT @dn = ISNULL(SUM(CASE WHEN adj_type = 'DEBIT_NOTE' THEN amount END), 0), @cn = ISNULL(SUM(CASE WHEN adj_type = 'CREDIT_NOTE' THEN amount END), 0)
            FROM dbo.payment_adjustment WHERE payment_sno = @p;

            INSERT INTO dbo.acct_journal (journal_date, source_type, source_sno, narration, com_sno, div_sno, brn_sno, dept_sno, created_by)
            VALUES (@vdate, 'PAYMENT', @p, N'Payment ' + @pn, @jc, @jd, @jb, @jdp, @by);
            SET @j = SCOPE_IDENTITY();
            UPDATE dbo.acct_journal SET journal_no = 'JV-' + RIGHT('000000' + CAST(@j AS VARCHAR(6)), 6) WHERE journal_sno = @j;

            DELETE FROM @jl;
            INSERT INTO @jl VALUES (@h_pay, @gross + @cn, 0);
            IF @tds > 0 INSERT INTO @jl VALUES (@h_tds, 0, @tds);
            IF @adv > 0 INSERT INTO @jl VALUES (@h_adv, 0, @adv);
            IF @net > 0 INSERT INTO @jl VALUES (@h_bank, 0, @net);
            IF @dn > 0  INSERT INTO @jl VALUES (@h_dn, 0, @dn);
            IF @cn > 0  BEGIN INSERT INTO @jl VALUES (@h_dn, @cn, 0); INSERT INTO @jl VALUES (@h_pay, 0, @cn); END
            IF (SELECT SUM(debit) - SUM(credit) FROM @jl) <> 0 THROW 56109, 'Payment journal is not balanced.', 1;
            INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno) SELECT @j, head_sno, debit, credit, @pv FROM @jl;
            UPDATE dbo.payment_info SET journal_sno = @j WHERE payment_sno = @p;

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
           i.channel, i.beneficiary_name, i.account_no, i.ifsc, i.bank_name, i.branch_name, i.invoice_nos, i.supplier_invoice_nos, i.msme_label, i.narration, i.gross_amount, i.tds_amount, i.advance_amount, i.note_amount,
           p.com_sno, p.div_sno, p.brn_sno, p.dept_sno
    FROM dbo.payment_batch_item i JOIN dbo.payment_info p ON p.payment_sno = i.payment_sno
    WHERE i.batch_sno = @bsno ORDER BY i.line_no;

    SELECT l.batch_item_sno, l.batch_sno, l.payment_sno, l.invoice_sno, l.invoice_no, l.supplier_invoice_no, l.invoice_date, l.invoice_amount, l.gst_amount,
           l.payable_total, l.paid_before, l.this_gross, l.tds_amount, l.balance_after, l.awaiting_2b, l.part_no, l.kind
    FROM dbo.payment_batch_item_invoice l WHERE l.batch_sno = @bsno
    ORDER BY l.batch_item_sno, l.invoice_sno;
END
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
