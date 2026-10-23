-- ============================================================
-- 64_payment_note_scope.sql   (Non_trade_Dev ONLY, re-runnable)
-- Debit / credit notes on the Payment page: which bills may redeem which note.
--
-- Before: sp_nt_GetPaymentAdjustments offered EVERY unredeemed note of the supplier on every payment, so a note raised against
-- a bill that is still to be paid showed up on the supplier's other bills, and two people paying two bills could both tick
-- the same note (the second release then died on the unique index UX_payment_adjustment_note).
--
-- Rules now. A note is a debit or credit note; its "bill" is the supplier invoice(s) it was raised against:
--   1. Raised against a bill that is already PAID IN FULL -> usable on any other bill of the same supplier + company
--      ("supplier credit"). It is offered on every such bill until one payment redeems it, then it is gone from all of them.
--   2. Raised against a bill that is still OPEN           -> offered only while that bill is being paid, never on the
--      supplier's other bills.
--   3. A note is only offered against bills of its own company (com_sno).
--   4. A note whose bill has not been entered yet (no live invoice on its PO) is tied to no bill, so it is offered like a
--      paid-bill note: on any bill of the supplier + company. Once its bill is entered it belongs to that bill (rule 2).
-- Which bill a note belongs to: the invoice(s) that allocate the same PO line(s) the note was raised on; when no invoice bills
-- those lines, every live invoice on the note's PO. "Paid in full" is the invoice ledger's 'Paid' test (sql/63):
-- it has allocations, something was paid, and nothing releasable is left.
--
-- sp_nt_ReleasePaymentNet repeats the same check on the server (a stale or hand-built request cannot redeem a note it was
-- never offered), and now serialises releases per supplier with an application lock, so two payments racing for the same
-- note get a clear message instead of a unique-index error. It also returns the org of the payment for the live broadcast.
--
-- Apply: cd grn-service && node sql/run_sql.mjs sql/64_payment_note_scope.sql
-- Rollback: sql/backups/payment_note_scope_2026-10-22_ROLLBACK.sql
-- ============================================================

-- ── 1. every (note, bill) pair for a supplier's unredeemed notes ────────────
-- One row per note per source bill; invoice_sno is NULL when no bill has been entered for the note yet.
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
    inv AS (   -- the supplier's live invoices, and whether each is paid in full
        SELECT i.invoice_sno, i.po_basic_sno,
               i.invoice_no + CASE WHEN NULLIF(LTRIM(RTRIM(i.vendor_invoice_no)), '') IS NULL THEN '' ELSE ' (' + LTRIM(RTRIM(i.vendor_invoice_no)) + ')' END AS invoice_label,
               CAST(CASE WHEN a.alloc_count > 0 AND a.paid_total > 0 AND a.release_total - a.paid_total <= 0.01 THEN 1 ELSE 0 END AS BIT) AS is_closed
        FROM dbo.invoice_info i
        OUTER APPLY (
            SELECT COUNT(*) AS alloc_count, SUM(iad.release_amount) AS release_total, SUM(ISNULL(pd.paid, 0)) AS paid_total
            FROM dbo.invoice_allocation_details iad
            OUTER APPLY (SELECT SUM(pad.amount) AS paid FROM dbo.payment_allocation_details pad WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno) pd
            WHERE iad.invoice_sno = i.invoice_sno AND iad.is_active = 'Y'
        ) a
        WHERE i.vendor_sno = @vendor_sno AND i.is_active = 'Y'
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

-- ── 2. the notes that may be redeemed while paying a given set of bills ─────
-- @invoice_json = JSON array of invoice_sno being paid, e.g. '[12,14]'.
--   scope = 'OWN'      raised against a bill in this payment (that bill is still open)
--           'SUPPLIER' no open bill behind it - raised against bills that are all paid in full, or against a PO whose invoice
--                      is not entered yet (source_invoices is NULL then) - usable on any bill of the supplier
CREATE OR ALTER FUNCTION dbo.fn_nt_PaymentNotesForBills (@vendor_sno INT, @invoice_json NVARCHAR(MAX))
RETURNS TABLE
AS
RETURN
(
    WITH sel AS (   -- the bills being paid, with the company each belongs to (the invoice's own, else its PO's)
        SELECT DISTINCT i.invoice_sno, COALESCE(i.com_sno, p.com_sno) AS com_sno
        FROM OPENJSON(@invoice_json) j
        JOIN dbo.invoice_info i ON i.invoice_sno = TRY_CAST(j.value AS INT) AND i.vendor_sno = @vendor_sno AND i.is_active = 'Y'
        LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    ),
    st AS (
        SELECT s.note_type, s.note_sno, s.note_no, s.po_basic_sno, s.grn_basic_sno, s.com_sno, s.note_date, s.amount, s.remarks,
               SUM(CASE WHEN s.invoice_sno IS NOT NULL AND s.is_closed = 0 THEN 1 ELSE 0 END)             AS open_count,
               SUM(CASE WHEN s.invoice_sno IS NOT NULL AND s.is_closed = 0 AND sel.invoice_sno IS NOT NULL THEN 1 ELSE 0 END) AS in_sel,
               STRING_AGG(s.invoice_label, ', ')                                                            AS source_invoices
        FROM dbo.fn_nt_PaymentNoteScope(@vendor_sno) s
        LEFT JOIN sel ON sel.invoice_sno = s.invoice_sno
        GROUP BY s.note_type, s.note_sno, s.note_no, s.po_basic_sno, s.grn_basic_sno, s.com_sno, s.note_date, s.amount, s.remarks
    )
    SELECT st.note_type, st.note_sno, st.note_no, st.po_basic_sno, st.grn_basic_sno, st.com_sno, st.note_date, st.amount, st.remarks,
           CAST(CASE WHEN st.open_count = 0 THEN 'SUPPLIER' ELSE 'OWN' END AS VARCHAR(8)) AS scope,
           st.source_invoices
    FROM st
    WHERE EXISTS (SELECT 1 FROM sel)
      AND (st.open_count = 0                              -- no open bill behind it (all paid, or none entered yet): any bill of the supplier may use it
        OR (st.open_count > 0 AND st.in_sel > 0))         -- its bill is still open: only that bill may use it
      AND NOT EXISTS (SELECT 1 FROM sel WHERE sel.com_sno IS NOT NULL AND st.com_sno IS NOT NULL AND sel.com_sno <> st.com_sno)
);
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
END
GO

-- ── 4. release a payment with TDS / advance / note adjustments ──────────────
-- @jsonInput: { vendor_sno, payment_date, mode, bank_account?, reference_no?, remarks?, created_by, preview?, apply_tds?,
--   allocations: [{ invoice_alloc_sno, amount }], advances: [{ advance_sno, amount }], notes: [{ type: 'DEBIT'|'CREDIT', note_sno }] }
-- Same as sql/44 except: notes must be ones fn_nt_PaymentNotesForBills offers for the bills being paid (55022), a note
-- redeemed by another payment is named in the error (55024), releases for one supplier are serialised (55023), and the
-- result also carries the payment's org (com/div/brn/dept) for the live broadcast.
CREATE OR ALTER PROCEDURE dbo.sp_nt_ReleasePaymentNet
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @v INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @pdate DATE = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_date') AS DATE), CAST(GETDATE() AS DATE)),
            @mode VARCHAR(10) = JSON_VALUE(@jsonInput, '$.mode'), @bank VARCHAR(100) = JSON_VALUE(@jsonInput, '$.bank_account'),
            @ref VARCHAR(100) = JSON_VALUE(@jsonInput, '$.reference_no'), @rem VARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks'),
            @by VARCHAR(20) = JSON_VALUE(@jsonInput, '$.created_by'),
            @preview BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.preview') IN ('1', 'true') THEN 1 ELSE 0 END,
            @applyTds BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.apply_tds') IN ('0', 'false') THEN 0 ELSE 1 END,
            @allocJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.allocations'),
            @advJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.advances'),
            @noteJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.notes');
    IF @v IS NULL OR @mode IS NULL OR @by IS NULL OR @allocJson IS NULL THROW 55011, 'vendor_sno, mode, created_by and allocations are required.', 1;

    DECLARE @alloc TABLE (invoice_alloc_sno INT, amount DECIMAL(18,2));
    INSERT INTO @alloc SELECT TRY_CAST(JSON_VALUE(value, '$.invoice_alloc_sno') AS INT), TRY_CAST(JSON_VALUE(value, '$.amount') AS DECIMAL(18,2)) FROM OPENJSON(@allocJson);
    IF NOT EXISTS (SELECT 1 FROM @alloc) OR EXISTS (SELECT 1 FROM @alloc WHERE invoice_alloc_sno IS NULL OR amount IS NULL OR amount <= 0)
        THROW 55012, 'Each allocation needs an invoice_alloc_sno and a positive amount.', 1;

    -- same release limit rule as sp_nt_ReleasePayment, plus every bucket must belong to this supplier
    IF EXISTS (
        SELECT 1 FROM @alloc a
        LEFT JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = a.invoice_alloc_sno
        LEFT JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
        OUTER APPLY (SELECT ISNULL(SUM(pad.amount), 0) AS paid FROM dbo.payment_allocation_details pad WHERE pad.invoice_alloc_sno = a.invoice_alloc_sno) p
        WHERE iad.invoice_alloc_sno IS NULL OR i.vendor_sno <> @v OR a.amount > (iad.release_amount - p.paid) + 0.01
    )
        THROW 55013, 'An allocation is unknown, belongs to another supplier, or exceeds its unpaid release amount.', 1;

    DECLARE @gross DECIMAL(18,2) = (SELECT SUM(amount) FROM @alloc);

    -- per-invoice TDS
    DECLARE @inv TABLE (invoice_sno INT PRIMARY KEY, gross DECIMAL(18,2), base DECIMAL(18,2), section VARCHAR(10),
                        taxable DECIMAL(18,2) NULL, rate DECIMAL(6,3) NULL, tds DECIMAL(18,2) NOT NULL DEFAULT 0, fy INT NULL);
    INSERT INTO @inv (invoice_sno, gross, base, section)
    SELECT i.invoice_sno, SUM(a.amount),
           ROUND(SUM(a.amount) * CASE WHEN ISNULL(i.invoice_amount, 0) > 0 AND i.taxable_value IS NOT NULL THEN i.taxable_value / i.invoice_amount ELSE 1 END, 2),
           i.tds_section_code
    FROM @alloc a JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = a.invoice_alloc_sno
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    GROUP BY i.invoice_sno, i.invoice_amount, i.taxable_value, i.tds_section_code;

    -- optional per-invoice TDS section chosen on the payment screen: tds_overrides [{ invoice_sno, section }] ('' = no TDS)
    DECLARE @tdsJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.tds_overrides');
    IF @tdsJson IS NOT NULL
        UPDATE x SET section = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(o.value, '$.section')))), '')
        FROM @inv x JOIN OPENJSON(@tdsJson) o ON x.invoice_sno = TRY_CAST(JSON_VALUE(o.value, '$.invoice_sno') AS INT);

    -- GSTR-2B hold: a GST-registered supplier's invoice cannot be paid until 2B has matched it, unless Accounts released the hold (sql/45)
    IF EXISTS (SELECT 1 FROM @inv x JOIN dbo.invoice_info inv ON inv.invoice_sno = x.invoice_sno
               JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = inv.vendor_sno
               WHERE LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(inv.itc_status, '') NOT IN ('Eligible', 'Ineligible') AND ISNULL(inv.payment_hold_override, 'N') <> 'Y')
    BEGIN
        DECLARE @held NVARCHAR(400) = (SELECT STRING_AGG(inv.invoice_no, ', ') FROM @inv x JOIN dbo.invoice_info inv ON inv.invoice_sno = x.invoice_sno
               JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = inv.vendor_sno
               WHERE LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(inv.itc_status, '') NOT IN ('Eligible', 'Ineligible') AND ISNULL(inv.payment_hold_override, 'N') <> 'Y');
        DECLARE @heldMsg NVARCHAR(500) = N'Payment held until the invoice appears in GSTR-2B (or Accounts releases the hold): ' + @held;
        THROW 55021, @heldMsg, 1;
    END

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

    -- advances
    DECLARE @adv TABLE (advance_sno INT, amount DECIMAL(18,2));
    IF @advJson IS NOT NULL
        INSERT INTO @adv SELECT TRY_CAST(JSON_VALUE(value, '$.advance_sno') AS INT), TRY_CAST(JSON_VALUE(value, '$.amount') AS DECIMAL(18,2)) FROM OPENJSON(@advJson);
    IF EXISTS (SELECT 1 FROM @adv a LEFT JOIN dbo.nt_supplier_advance_payment s ON s.advance_sno = a.advance_sno AND s.vendor_sno = @v AND s.is_active = 'Y'
               WHERE a.amount IS NULL OR a.amount <= 0 OR s.advance_sno IS NULL OR a.amount > s.amount - s.adjusted_amount + 0.01)
        THROW 55014, 'An advance is unknown, belongs to another supplier, or the amount exceeds its balance.', 1;
    DECLARE @advTotal DECIMAL(18,2) = ISNULL((SELECT SUM(amount) FROM @adv), 0);
    IF @advTotal > @gross - @tds + 0.01 THROW 55015, 'Advance adjusted cannot exceed the amount payable after TDS.', 1;

    -- notes (sql/64: only notes offered for the bills being paid; a note already redeemed elsewhere is named)
    DECLARE @notes TABLE (note_type VARCHAR(6), note_sno INT, amount DECIMAL(18,2), note_no VARCHAR(60));
    IF @noteJson IS NOT NULL
        INSERT INTO @notes (note_type, note_sno) SELECT DISTINCT UPPER(JSON_VALUE(value, '$.type')), TRY_CAST(JSON_VALUE(value, '$.note_sno') AS INT) FROM OPENJSON(@noteJson);
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

    DECLARE @invJson NVARCHAR(MAX) = (SELECT '[' + STRING_AGG(CAST(invoice_sno AS VARCHAR(12)), ',') + ']' FROM @inv);
    DECLARE @offered TABLE (note_type VARCHAR(6), note_sno INT);
    INSERT INTO @offered SELECT note_type, note_sno FROM dbo.fn_nt_PaymentNotesForBills(@v, @invJson);
    IF EXISTS (SELECT 1 FROM @notes n WHERE NOT EXISTS (SELECT 1 FROM @offered o WHERE o.note_type = n.note_type AND o.note_sno = n.note_sno))
    BEGIN
        DECLARE @off NVARCHAR(400) = (SELECT STRING_AGG(n.note_no, ', ') FROM @notes n WHERE NOT EXISTS (SELECT 1 FROM @offered o WHERE o.note_type = n.note_type AND o.note_sno = n.note_sno));
        DECLARE @offMsg NVARCHAR(500) = N'Not available for the invoices being paid (its own bill is still open, or it belongs to another company): ' + @off;
        THROW 55022, @offMsg, 1;
    END

    DECLARE @dn DECIMAL(18,2) = ISNULL((SELECT SUM(amount) FROM @notes WHERE note_type = 'DEBIT'), 0),
            @cn DECIMAL(18,2) = ISNULL((SELECT SUM(amount) FROM @notes WHERE note_type = 'CREDIT'), 0);

    DECLARE @net DECIMAL(18,2) = @gross - @tds - @advTotal - @dn + @cn;
    IF @net < 0 THROW 55018, 'Debit notes and advances exceed what is payable - nothing to pay.', 1;

    IF @preview = 1
    BEGIN
        SELECT @gross AS gross_amount, @tds AS tds_amount, @advTotal AS advance_adjusted, @dn AS debit_notes, @cn AS credit_notes, @net AS net_paid;
        SELECT i.invoice_sno, inv.invoice_no, i.gross, i.base AS taxable_base, i.section AS tds_section, i.rate AS tds_rate_pct, i.taxable AS tds_taxable, i.tds AS tds_amount
        FROM @inv i JOIN dbo.invoice_info inv ON inv.invoice_sno = i.invoice_sno;
        RETURN;
    END

    DECLARE @h_pay INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'SUPPLIER_PAYABLE'),
            @h_tds INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'TDS_PAYABLE'),
            @h_adv INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'ADVANCE_SUPPLIER'),
            @h_bank INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'BANK'),
            @h_dn INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'DN_ADJ');
    IF @h_pay IS NULL OR @h_tds IS NULL OR @h_adv IS NULL OR @h_bank IS NULL OR @h_dn IS NULL THROW 55019, 'System account heads are missing.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        -- one release per supplier at a time: the re-check below cannot race another payment for the same note
        DECLARE @lockName NVARCHAR(100) = N'pay_release_vendor_' + CAST(@v AS NVARCHAR(12)), @lk INT;
        EXEC @lk = sp_getapplock @Resource = @lockName, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
        IF @lk < 0 THROW 55023, 'Another payment for this supplier is being released right now - please try again in a moment.', 1;
        SET @gone = (SELECT STRING_AGG(n.note_no + ' (' + ISNULL(pi.payment_no, 'another payment') + ')', ', ')
            FROM @notes n JOIN dbo.payment_adjustment pa ON pa.adj_type = CASE n.note_type WHEN 'DEBIT' THEN 'DEBIT_NOTE' ELSE 'CREDIT_NOTE' END AND pa.ref_sno = n.note_sno
            LEFT JOIN dbo.payment_info pi ON pi.payment_sno = pa.payment_sno);
        IF @gone IS NOT NULL
        BEGIN
            SET @goneMsg = N'Already redeemed in another payment - refresh and untick it: ' + @gone;
            THROW 55024, @goneMsg, 1;
        END

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(payment_no, 6) AS INT)), 0) + 1 FROM dbo.payment_info WITH (UPDLOCK, HOLDLOCK) WHERE payment_no LIKE 'PAY-' + @year + '-%';
        DECLARE @pno VARCHAR(30) = 'PAY-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6), @psno INT;

        INSERT INTO dbo.payment_info (payment_no, vendor_sno, payment_date, amount, mode, bank_account, reference_no, status, remarks, is_active, created_by, created_date,
                                      gross_amount, tds_amount, advance_adjusted, note_adjusted, net_paid)
        VALUES (@pno, @v, @pdate, @gross, @mode, @bank, @ref, 'Processed', @rem, 'Y', @by, GETDATE(), @gross, @tds, @advTotal, @dn - @cn, @net);
        SET @psno = SCOPE_IDENTITY();

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

        -- journal
        DECLARE @com INT, @div INT, @brn INT, @dept INT, @j INT;
        SELECT TOP 1 @com = i.com_sno, @div = i.div_sno, @brn = i.brn_sno, @dept = i.dept_sno
        FROM @inv x JOIN dbo.invoice_info i ON i.invoice_sno = x.invoice_sno;
        INSERT INTO dbo.acct_journal (journal_date, source_type, source_sno, narration, com_sno, div_sno, brn_sno, dept_sno, created_by)
        VALUES (@pdate, 'PAYMENT', @psno, N'Payment ' + @pno, @com, @div, @brn, @dept, @by);
        SET @j = SCOPE_IDENTITY();
        UPDATE dbo.acct_journal SET journal_no = 'JV-' + RIGHT('000000' + CAST(@j AS VARCHAR(6)), 6) WHERE journal_sno = @j;

        DECLARE @jl TABLE (head_sno INT, debit DECIMAL(18,2), credit DECIMAL(18,2));
        INSERT INTO @jl VALUES (@h_pay, @gross + @cn, 0);
        IF @tds > 0      INSERT INTO @jl VALUES (@h_tds, 0, @tds);
        IF @advTotal > 0 INSERT INTO @jl VALUES (@h_adv, 0, @advTotal);
        IF @net > 0      INSERT INTO @jl VALUES (@h_bank, 0, @net);
        IF @dn > 0       INSERT INTO @jl VALUES (@h_dn, 0, @dn);
        IF @cn > 0       BEGIN INSERT INTO @jl VALUES (@h_dn, @cn, 0); INSERT INTO @jl VALUES (@h_pay, 0, @cn); END
        IF (SELECT SUM(debit) - SUM(credit) FROM @jl) <> 0 THROW 55020, 'Payment journal is not balanced.', 1;
        INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno) SELECT @j, head_sno, debit, credit, @v FROM @jl;
        UPDATE dbo.payment_info SET journal_sno = @j WHERE payment_sno = @psno;

        -- org of the payment for the live broadcast (the invoice's own, else its PO's - some invoices carry no company)
        DECLARE @bcom INT, @bdiv INT, @bbrn INT, @bdept INT;
        SELECT TOP 1 @bcom  = IIF(i.com_sno IS NULL, p.com_sno,  i.com_sno),  @bdiv  = IIF(i.com_sno IS NULL, p.div_sno,  i.div_sno),
                     @bbrn  = IIF(i.com_sno IS NULL, p.brn_sno,  i.brn_sno),  @bdept = IIF(i.com_sno IS NULL, p.dept_sno, i.dept_sno)
        FROM @inv x JOIN dbo.invoice_info i ON i.invoice_sno = x.invoice_sno
        LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
        ORDER BY x.invoice_sno;

        COMMIT TRANSACTION;
        SELECT @psno AS payment_sno, @pno AS payment_no, @gross AS gross_amount, @tds AS tds_amount, @advTotal AS advance_adjusted,
               @dn AS debit_notes, @cn AS credit_notes, @net AS net_paid, @j AS journal_sno, 'SUCCESS' AS result,
               @bcom AS com_sno, @bdiv AS div_sno, @bbrn AS brn_sno, @bdept AS dept_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO
