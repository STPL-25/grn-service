-- Rollback of sql/79: puts back the definitions that were live before (hold at the Payment screen) and drops the check.
IF OBJECT_ID('dbo.sp_nt_ApplyGst2bCheck', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_ApplyGst2bCheck;
GO
-- 76: an invoice that is not in GSTR-2B is never held back from payment - it is paid WITHOUT its GST and the GST is listed as unpaid
--
-- sql/70 held the WHOLE invoice when it carried no taxable value (it could not be split into taxable and GST).  Now every invoice
-- can be split: the taxable value is the one on the invoice (typed on the GRN), else worked back from the GST % on the PO lines,
-- else - the PO carries no GST rate, so no GST is known - the whole invoice amount.  A GST-registered supplier's invoice that is not in
-- GSTR-2B (and has no Accounts hold release) is therefore payable up to its taxable value at once; the GST part goes to the Unpaid GST
-- screen and moves to Payment Run when a 2B upload has the invoice (sql/75).
--
-- Re-runnable.  Rollback: sql/backups/pay_without_gst_2026-11-01_ROLLBACK.sql

-- what can be paid on one bill right now
--   taxable_eff   the invoice's taxable value (see above)
--   taxable_part  the share of this bill that is taxable value - TDS base
--   gst_part      the rest (GST and anything else on top of the taxable value)
--   hold_2b       what may not be paid yet because 2B does not have the invoice (= the GST part)
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
           CAST(CASE WHEN iad.release_amount - h.hold_2b - pd.settled - pd.reserved > 0 THEN iad.release_amount - h.hold_2b - pd.settled - pd.reserved ELSE 0 END AS DECIMAL(18,2)) AS payable_now,
           te.taxable_eff
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
    OUTER APPLY (
        SELECT ISNULL(SUM(ISNULL(p.net_cost, 0) * ISNULL(p.tax_pct, 0)) / NULLIF(SUM(ISNULL(p.net_cost, 0)), 0), 0) AS pct
        FROM dbo.po_item_details p WHERE p.po_basic_sno = i.po_basic_sno AND p.is_active IN ('Y', '1')
    ) pp
    CROSS APPLY (
        SELECT CAST(CASE WHEN ISNULL(i.invoice_amount, 0) <= 0 THEN NULL
                         WHEN i.taxable_value IS NOT NULL AND i.taxable_value > 0 AND i.taxable_value <= i.invoice_amount THEN i.taxable_value
                         WHEN pp.pct > 0 THEN ROUND(i.invoice_amount / (1 + pp.pct / 100.0), 2)
                         ELSE i.invoice_amount END AS DECIMAL(18,2)) AS taxable_eff
    ) te
    CROSS APPLY (
        SELECT CAST(CASE WHEN LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(i.itc_status, '') NOT IN ('Eligible', 'Ineligible')
                              AND ISNULL(i.payment_hold_override, 'N') <> 'Y' THEN 1 ELSE 0 END AS BIT) AS on_hold_2b,
               CAST(CASE WHEN te.taxable_eff IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS taxable_known
    ) x
    CROSS APPLY (
        SELECT CAST(CASE WHEN x.taxable_known = 1 THEN ROUND(iad.release_amount * te.taxable_eff / i.invoice_amount, 2) ELSE iad.release_amount END AS DECIMAL(18,2)) AS taxable_part
    ) t
    CROSS APPLY (
        SELECT CAST(CASE WHEN x.on_hold_2b = 0 THEN 0
                         WHEN x.taxable_known = 1 THEN iad.release_amount - t.taxable_part
                         ELSE iad.release_amount END AS DECIMAL(18,2)) AS hold_2b
    ) h
    WHERE (@invoice_alloc_sno IS NULL OR iad.invoice_alloc_sno = @invoice_alloc_sno)
);
GO

-- ── TDS rate can be typed on the payment (tds_overrides[].rate), remembered on the invoice ──
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
                        taxable DECIMAL(18,2) NULL, rate DECIMAL(6,3) NULL, tds DECIMAL(18,2) NOT NULL DEFAULT 0, fy INT NULL, rate_override DECIMAL(6,3) NULL);
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
        INSERT INTO @inv (invoice_sno, gross, base, section, rate_override)
        SELECT i.invoice_sno, SUM(a.amount),
               ROUND(SUM(CASE WHEN bp.settled + bp.reserved + a.amount < bp.taxable_part THEN bp.settled + bp.reserved + a.amount ELSE bp.taxable_part END
                        - CASE WHEN bp.settled + bp.reserved < bp.taxable_part THEN bp.settled + bp.reserved ELSE bp.taxable_part END), 2),
               i.tds_section_code, i.tds_rate_override
        FROM @alloc a
        JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = a.invoice_alloc_sno
        JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
        CROSS APPLY dbo.fn_nt_BillPayable(a.invoice_alloc_sno) bp
        GROUP BY i.invoice_sno, i.tds_section_code, i.tds_rate_override;

        DECLARE @gross DECIMAL(18,2) = (SELECT SUM(amount) FROM @alloc);

        -- optional per-invoice TDS section chosen on the payment screen: tds_overrides [{ invoice_sno, section }] ('' = no TDS)
        IF @tdsJson IS NOT NULL
            UPDATE x SET section = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(o.value, '$.section')))), ''),
                         rate_override = TRY_CAST(NULLIF(LTRIM(RTRIM(JSON_VALUE(o.value, '$.rate'))), '') AS DECIMAL(6,3))
            FROM @inv x JOIN OPENJSON(@tdsJson) o ON x.invoice_sno = TRY_CAST(JSON_VALUE(o.value, '$.invoice_sno') AS INT);

        IF EXISTS (SELECT 1 FROM @inv WHERE rate_override < 0 OR rate_override > 100) THROW 55040, 'The TDS rate must be between 0 and 100 percent.', 1;

        IF @applyTds = 1
        BEGIN
            DECLARE @isno INT, @ibase DECIMAL(18,2), @isec VARCHAR(10), @t DECIMAL(18,2), @r DECIMAL(6,3), @tx DECIMAL(18,2), @fy INT, @ro DECIMAL(6,3);
            DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT invoice_sno, base, section, rate_override FROM @inv WHERE section IS NOT NULL ORDER BY invoice_sno;
            OPEN cur; FETCH NEXT FROM cur INTO @isno, @ibase, @isec, @ro;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                DECLARE @xp DECIMAL(18,2) = ISNULL((SELECT SUM(base) FROM @inv WHERE section = @isec AND taxable IS NOT NULL), 0),
                        @xd DECIMAL(18,2) = ISNULL((SELECT SUM(taxable) FROM @inv WHERE section = @isec AND taxable IS NOT NULL), 0);
                EXEC dbo.sp_nt_CalcTDS @vendor_sno = @v, @section = @isec, @base = @ibase, @on_date = @pdate,
                     @extra_prior = @xp, @extra_deducted = @xd, @tds = @t OUTPUT, @rate = @r OUTPUT, @taxable = @tx OUTPUT, @fy = @fy OUTPUT;
                -- a rate typed on the payment screen replaces the section's rate (the threshold logic still decides how much is taxable)
                IF @ro IS NOT NULL BEGIN SET @r = @ro; SET @t = ROUND(@tx * @ro / 100.0, 0); END
                UPDATE @inv SET taxable = @tx, rate = @r, tds = @t, fy = @fy WHERE invoice_sno = @isno;
                FETCH NEXT FROM cur INTO @isno, @ibase, @isec, @ro;
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
            UPDATE inv SET tds_section_code = x.section, tds_rate_override = x.rate_override FROM dbo.invoice_info inv JOIN @inv x ON x.invoice_sno = inv.invoice_sno;

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

-- ── unpaid GST: note it, and move it to Payment Run once 2B has the invoice ──
-- A bill whose taxable value is fully paid but whose GST is still unpaid is "unpaid GST" (it was held because the invoice was not in
-- GSTR-2B).  Nothing is paid for it until a 2B upload has the invoice (or Accounts releases the hold): then the unpaid GST becomes an
-- already approved payment of that supplier (no TDS - it is only GST) and waits in Payment Run next to the other approved payments.
-- Called after a payment's final approval, after every 2B upload / confirm / hold release, and from the Unpaid GST screen.
-- @jsonInput: { vendor_sno?, by?, release? (default 1; 0 = only refresh the register) } -> the payments created
CREATE OR ALTER PROCEDURE dbo.sp_nt_ReleaseGstAfter2b
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @v INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @by VARCHAR(20) = ISNULL(LEFT(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.by'))), ''), 20), 'SYSTEM'),
            @release BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.release') IN ('0', 'false') THEN 0 ELSE 1 END,
            @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    DECLARE @res TABLE (payment_sno INT, payment_no VARCHAR(30), vendor_sno INT, net_paid DECIMAL(18,2), com_sno INT, div_sno INT, brn_sno INT, dept_sno INT, invoice_nos NVARCHAR(400));

    -- 1. note every bill whose taxable part is paid (payment approved) and whose GST is still unpaid
    INSERT INTO dbo.payment_gst_pending (invoice_alloc_sno, invoice_sno, vendor_sno, gst_amount)
    SELECT iad.invoice_alloc_sno, iad.invoice_sno, i.vendor_sno, bp.outstanding
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno AND i.is_active = 'Y'
    CROSS APPLY dbo.fn_nt_BillPayable(iad.invoice_alloc_sno) bp
    CROSS APPLY (SELECT ISNULL(SUM(pad.amount), 0) AS paid_final
                 FROM dbo.payment_allocation_details pad JOIN dbo.payment_info py ON py.payment_sno = pad.payment_sno
                 WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno AND py.status NOT IN ('Pending Approval', 'Rejected', 'Cancelled')) fin
    WHERE iad.is_active = 'Y' AND i.vendor_sno IS NOT NULL AND bp.taxable_known = 1 AND bp.gst_part > 0.01
      AND fin.paid_final > 0 AND fin.paid_final >= bp.taxable_part - 0.01 AND bp.outstanding > 0.01
      AND (@v IS NULL OR i.vendor_sno = @v)
      AND NOT EXISTS (SELECT 1 FROM dbo.payment_gst_pending x WHERE x.invoice_alloc_sno = iad.invoice_alloc_sno);

    -- 2. a release that was rejected / cancelled before it was paid is handed back: the GST is an ordinary open balance on the Payment screen again
    UPDATE g SET status = 'Closed', closed_at = GETDATE()
    FROM dbo.payment_gst_pending g JOIN dbo.payment_info p ON p.payment_sno = g.released_payment_sno
    WHERE g.status = 'Released' AND p.status IN ('Rejected', 'Cancelled') AND (@v IS NULL OR g.vendor_sno = @v);

    -- 3. the GST was paid some other way (through the Payment screen once 2B had it)
    UPDATE g SET status = 'Closed', closed_at = GETDATE()
    FROM dbo.payment_gst_pending g CROSS APPLY dbo.fn_nt_BillPayable(g.invoice_alloc_sno) bp
    WHERE g.status = 'Awaiting 2B' AND bp.outstanding <= 0.01 AND (@v IS NULL OR g.vendor_sno = @v);

    IF @release = 1
    BEGIN
        DECLARE @vs TABLE (vendor_sno INT PRIMARY KEY);
        INSERT @vs
        SELECT DISTINCT g.vendor_sno
        FROM dbo.payment_gst_pending g
        JOIN dbo.invoice_info i ON i.invoice_sno = g.invoice_sno AND i.is_active = 'Y'
        CROSS APPLY dbo.fn_nt_BillPayable(g.invoice_alloc_sno) bp
        WHERE g.status = 'Awaiting 2B' AND bp.on_hold_2b = 0 AND bp.outstanding > 0.01 AND (@v IS NULL OR g.vendor_sno = @v);

        DECLARE @cv INT, @mode VARCHAR(10), @bank VARCHAR(100), @com INT, @div INT, @brn INT, @dept INT, @gross DECIMAL(18,2), @psno INT, @pno VARCHAR(30),
                @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT, @lockName NVARCHAR(100), @lk INT, @invnos NVARCHAR(400);
        DECLARE @lines TABLE (pending_sno INT, invoice_alloc_sno INT, amount DECIMAL(18,2));
        DECLARE vc CURSOR LOCAL FAST_FORWARD FOR SELECT vendor_sno FROM @vs ORDER BY vendor_sno;
        OPEN vc; FETCH NEXT FROM vc INTO @cv;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                IF @own = 1 BEGIN TRANSACTION; ELSE SAVE TRANSACTION rel_gst;
                SET @lockName = N'pay_release_vendor_' + CAST(@cv AS NVARCHAR(12));
                EXEC @lk = sp_getapplock @Resource = @lockName, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
                IF @lk < 0 THROW 55023, 'Another payment for this supplier is being saved right now.', 1;

                DELETE @lines;
                INSERT @lines
                SELECT g.pending_sno, g.invoice_alloc_sno, bp.outstanding
                FROM dbo.payment_gst_pending g
                JOIN dbo.invoice_info i ON i.invoice_sno = g.invoice_sno AND i.is_active = 'Y'
                CROSS APPLY dbo.fn_nt_BillPayable(g.invoice_alloc_sno) bp
                WHERE g.status = 'Awaiting 2B' AND g.vendor_sno = @cv AND bp.on_hold_2b = 0 AND bp.outstanding > 0.01;

                IF EXISTS (SELECT 1 FROM @lines)
                BEGIN
                    SET @mode = NULL; SET @bank = NULL; SET @com = NULL; SET @div = NULL; SET @brn = NULL; SET @dept = NULL;
                    -- how the supplier was paid before, and the organisation of that payment
                    SELECT TOP 1 @mode = p.mode, @bank = p.bank_account, @com = p.com_sno, @div = p.div_sno, @brn = p.brn_sno, @dept = p.dept_sno
                    FROM dbo.payment_allocation_details pad
                    JOIN dbo.payment_info p ON p.payment_sno = pad.payment_sno
                    WHERE pad.invoice_alloc_sno IN (SELECT invoice_alloc_sno FROM @lines) AND p.status NOT IN ('Pending Approval', 'Rejected', 'Cancelled')
                    ORDER BY p.payment_sno DESC;
                    IF @com IS NULL
                        SELECT TOP 1 @com = IIF(i.com_sno IS NULL, po.com_sno, i.com_sno), @div = IIF(i.com_sno IS NULL, po.div_sno, i.div_sno),
                                     @brn = IIF(i.com_sno IS NULL, po.brn_sno, i.brn_sno), @dept = IIF(i.com_sno IS NULL, po.dept_sno, i.dept_sno)
                        FROM @lines l JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = l.invoice_alloc_sno
                        JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = i.po_basic_sno
                        ORDER BY l.invoice_alloc_sno;
                    SET @mode = ISNULL(@mode, 'NEFT');
                    SELECT @gross = SUM(amount) FROM @lines;
                    SET @invnos = (SELECT STRING_AGG(x.invoice_no, ', ') FROM (SELECT DISTINCT i.invoice_no FROM @lines l
                                   JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = l.invoice_alloc_sno JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno) x);

                    SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(payment_no, 6) AS INT)), 0) + 1 FROM dbo.payment_info WITH (UPDLOCK, HOLDLOCK) WHERE payment_no LIKE 'PAY-' + @year + '-%';
                    SET @pno = 'PAY-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);
                    INSERT INTO dbo.payment_info (payment_no, vendor_sno, payment_date, amount, mode, bank_account, status, remarks, is_active, created_by, created_date,
                                                  gross_amount, tds_amount, advance_adjusted, note_adjusted, net_paid, com_sno, div_sno, brn_sno, dept_sno, approved_at, payment_type)
                    VALUES (@pno, @cv, CAST(GETDATE() AS DATE), @gross, @mode, @bank, 'Approved', LEFT(N'GST released - invoice now in GSTR-2B: ' + ISNULL(@invnos, N''), 500), 'Y', @by, GETDATE(),
                            @gross, 0, 0, 0, @gross, @com, @div, @brn, @dept, GETDATE(), 'BILL');
                    SET @psno = SCOPE_IDENTITY();
                    INSERT INTO dbo.payment_allocation_details (payment_sno, invoice_alloc_sno, amount, created_date) SELECT @psno, invoice_alloc_sno, amount, GETDATE() FROM @lines;
                    INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment)
                    VALUES (@psno, 'AUTO_APPROVED', @by, N'The unpaid GST of ' + ISNULL(@invnos, N'') + N' was approved with the payment of its invoice; GSTR-2B now has the invoice');
                    UPDATE g SET status = 'Released', released_payment_sno = @psno, released_at = GETDATE()
                    FROM dbo.payment_gst_pending g JOIN @lines l ON l.pending_sno = g.pending_sno;
                    INSERT @res VALUES (@psno, @pno, @cv, @gross, @com, @div, @brn, @dept, @invnos);
                END
                IF @own = 1 COMMIT TRANSACTION;
            END TRY
            BEGIN CATCH
                IF @own = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
                ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION rel_gst;
                IF @own = 0 THROW;
            END CATCH
            FETCH NEXT FROM vc INTO @cv;
        END
        CLOSE vc; DEALLOCATE vc;
        SELECT payment_sno, payment_no, vendor_sno, net_paid, com_sno, div_sno, brn_sno, dept_sno, invoice_nos FROM @res ORDER BY payment_sno;
    END
END
GO

-- ── Payment list: posts GRN invoices; carries the invoice TDS rate ──
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

    -- invoices captured on approved GRNs become payable here (sql/75)
    BEGIN TRY
        EXEC dbo.sp_nt_SyncGrnInvoicesToPayables;
    END TRY
    BEGIN CATCH
    END CATCH

    SELECT
        iad.invoice_alloc_sno AS bill_sno, i.invoice_sno, i.invoice_no AS bill_no, i.vendor_invoice_no AS supplier_invoice_no,
        p.po_df_no AS po_no, i.vendor_sno, k.company_name AS vendor_name, i.invoice_date, i.due_date, iad.bucket_type,
        iad.allocated_amount, iad.hold_amount, iad.release_amount AS net_payable,
        paid.paidSoFar AS paid_amount, paid.reservedSoFar AS reserved_amount,
        iad.release_amount - paid.paidSoFar - paid.reservedSoFar AS outstanding,
        i.invoice_amount, bp.taxable_eff AS taxable_value, i.tds_section_code, i.tds_rate_override, i.itc_status, i.payment_hold_override,
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
-- Payments already cut by the check stay cut; their GST stays on payment_gst_pending (Unpaid GST).
