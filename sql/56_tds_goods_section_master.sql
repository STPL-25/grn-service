-- ============================================================
-- 56_tds_goods_section_master.sql   (Non_trade_Dev ONLY)
-- The pending-payment TDS estimate used a hard-coded '194Q'. The section is now whichever row of tds_section_master has
-- is_goods_default = 'Y' (194Q seeded), so rates / thresholds / the default goods section are all master data.
-- Rest of sp_nt_GetGrnPendingPayments is unchanged from sql/53.
-- ============================================================
IF COL_LENGTH('dbo.tds_section_master', 'is_goods_default') IS NULL
    ALTER TABLE dbo.tds_section_master ADD is_goods_default CHAR(1) NOT NULL CONSTRAINT DF_tds_goods_default DEFAULT 'N';
GO
UPDATE dbo.tds_section_master SET is_goods_default = 'Y' WHERE section_code = '194Q'
  AND NOT EXISTS (SELECT 1 FROM dbo.tds_section_master WHERE is_goods_default = 'Y');
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGrnPendingPayments
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @inc BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.include_billed') IN ('1', 'true') THEN 1 ELSE 0 END;

    CREATE TABLE #r (po_basic_sno INT PRIMARY KEY, po_no VARCHAR(50), vendor_sno INT, vendor_name NVARCHAR(200),
                     grn_count INT, grn_nos NVARCHAR(400), last_received_date DATETIME,
                     ordered_qty DECIMAL(18,3), received_qty DECIMAL(18,3),
                     po_taxable DECIMAL(18,2), po_gst DECIMAL(18,2), taxable_value DECIMAL(18,2), gst_value DECIMAL(18,2),
                     debit_notes DECIMAL(18,2), credit_notes DECIMAL(18,2), advances DECIMAL(18,2), tds_estimate DECIMAL(18,2) NOT NULL DEFAULT 0);

    ;WITH pend AS (
        SELECT DISTINCT p.po_basic_sno
        FROM dbo.grn_basic_info g JOIN dbo.po_request_info p ON p.po_basic_sno = g.po_basic_sno
        WHERE p.vendor_sno IS NOT NULL AND g.is_active = 'Y' AND g.status IN ('Approved', 'Received')
          AND (@inc = 1 OR NOT EXISTS (SELECT 1 FROM dbo.invoice_info i WHERE i.po_basic_sno = p.po_basic_sno AND i.is_active = 'Y'))
          AND (@vendor_sno IS NULL OR p.vendor_sno = @vendor_sno)
    ), lines AS (   -- one row per PO line: received qty summed across its approved GRNs
        SELECT pi.po_basic_sno, pi.po_item_sno, pi.qty AS ordered_qty,
               ISNULL(SUM(gi.received_qty), 0) AS received_qty,
               ISNULL(pi.agreed_unit_price, 0) * (1 - ISNULL(pi.discount_pct, 0) / 100.0) AS net_rate,
               ISNULL(pi.tax_pct, 0) AS tax_pct
        FROM dbo.po_item_details pi
        JOIN pend ON pend.po_basic_sno = pi.po_basic_sno
        LEFT JOIN dbo.grn_item_details gi ON gi.po_item_sno = pi.po_item_sno AND gi.is_active = 'Y'
             AND EXISTS (SELECT 1 FROM dbo.grn_basic_info g WHERE g.grn_basic_sno = gi.grn_basic_sno AND g.is_active = 'Y' AND g.status IN ('Approved', 'Received'))
        WHERE pi.is_active IN ('Y', '1')
        GROUP BY pi.po_basic_sno, pi.po_item_sno, pi.qty, pi.agreed_unit_price, pi.discount_pct, pi.tax_pct
    )
    INSERT INTO #r (po_basic_sno, po_no, vendor_sno, vendor_name, grn_count, grn_nos, last_received_date,
                    ordered_qty, received_qty, po_taxable, po_gst, taxable_value, gst_value, debit_notes, credit_notes, advances)
    SELECT p.po_basic_sno, p.po_df_no, p.vendor_sno, k.company_name,
           (SELECT COUNT(*) FROM dbo.grn_basic_info g WHERE g.po_basic_sno = p.po_basic_sno AND g.is_active = 'Y' AND g.status IN ('Approved', 'Received')),
           (SELECT STRING_AGG(CAST(d.grn_no AS VARCHAR(30)), ', ') WITHIN GROUP (ORDER BY d.grn_basic_sno)
              FROM (SELECT g2.grn_basic_sno, g2.grn_no FROM dbo.grn_basic_info g2
                     WHERE g2.po_basic_sno = p.po_basic_sno AND g2.is_active = 'Y' AND g2.status IN ('Approved', 'Received')) d),
           (SELECT MAX(g3.received_date) FROM dbo.grn_basic_info g3 WHERE g3.po_basic_sno = p.po_basic_sno AND g3.is_active = 'Y' AND g3.status IN ('Approved', 'Received')),
           ISNULL(SUM(l.ordered_qty), 0), ISNULL(SUM(l.received_qty), 0),
           ROUND(ISNULL(SUM(l.ordered_qty * l.net_rate), 0), 2),
           ROUND(ISNULL(SUM(l.ordered_qty * l.net_rate * l.tax_pct / 100.0), 0), 2),
           ROUND(ISNULL(SUM(l.received_qty * l.net_rate), 0), 2),
           ROUND(ISNULL(SUM(l.received_qty * l.net_rate * l.tax_pct / 100.0), 0), 2),
           ISNULL((SELECT SUM(di.amount) FROM dbo.debit_note_basic_info d JOIN dbo.debit_note_item_details di ON di.debit_note_sno = d.debit_note_sno AND di.is_active = 'Y'
                    WHERE d.po_basic_sno = p.po_basic_sno AND d.is_active = 'Y' AND ISNULL(di.reason_type, '') <> 'Shortage'
                      AND NOT EXISTS (SELECT 1 FROM dbo.payment_adjustment pa WHERE pa.adj_type = 'DEBIT_NOTE' AND pa.ref_sno = d.debit_note_sno)), 0),
           ISNULL((SELECT SUM(c.total_amount) FROM dbo.credit_note_basic_info c WHERE c.po_basic_sno = p.po_basic_sno AND c.is_active = 'Y'
                    AND NOT EXISTS (SELECT 1 FROM dbo.payment_adjustment pa WHERE pa.adj_type = 'CREDIT_NOTE' AND pa.ref_sno = c.credit_note_sno)), 0),
           ISNULL((SELECT SUM(a.amount - a.adjusted_amount) FROM dbo.nt_supplier_advance_payment a
                    WHERE a.po_basic_sno = p.po_basic_sno AND a.is_active = 'Y' AND a.amount - a.adjusted_amount > 0), 0)
    FROM pend JOIN dbo.po_request_info p ON p.po_basic_sno = pend.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = p.vendor_sno
    LEFT JOIN lines l ON l.po_basic_sno = p.po_basic_sno
    GROUP BY p.po_basic_sno, p.po_df_no, p.vendor_sno, k.company_name;

    -- goods TDS estimate per PO, using the section flagged is_goods_default in tds_section_master (no hard-coded section); a failing lookup leaves it at 0 rather than hiding the row
    DECLARE @goodsSec VARCHAR(10) = (SELECT TOP 1 section_code FROM dbo.tds_section_master WHERE is_goods_default = 'Y' AND is_active = 'Y' ORDER BY section_code);
    DECLARE @po INT, @v INT, @base DECIMAL(18,2), @t DECIMAL(18,2), @rt DECIMAL(6,3), @tx DECIMAL(18,2), @fy INT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT po_basic_sno, vendor_sno, taxable_value FROM #r WHERE taxable_value > 0 AND @goodsSec IS NOT NULL;
    OPEN c; FETCH NEXT FROM c INTO @po, @v, @base;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC dbo.sp_nt_CalcTDS @vendor_sno = @v, @section = @goodsSec, @base = @base, @on_date = NULL,
                 @tds = @t OUTPUT, @rate = @rt OUTPUT, @taxable = @tx OUTPUT, @fy = @fy OUTPUT;
            UPDATE #r SET tds_estimate = ISNULL(@t, 0) WHERE po_basic_sno = @po;
        END TRY
        BEGIN CATCH
        END CATCH
        FETCH NEXT FROM c INTO @po, @v, @base;
    END
    CLOSE c; DEALLOCATE c;

    SELECT po_basic_sno, po_no, vendor_sno, vendor_name,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.invoice_info i WHERE i.po_basic_sno = #r.po_basic_sno AND i.is_active = 'Y') THEN 1 ELSE 0 END AS BIT) AS has_invoice,
           grn_count, grn_nos, last_received_date,
           ordered_qty, received_qty, received_qty - ordered_qty AS qty_variance,
           taxable_value, gst_value, taxable_value + gst_value AS grn_value,
           gst_value - po_gst AS gst_variance, taxable_value - po_taxable AS taxable_variance,
           debit_notes, credit_notes, advances, tds_estimate,
           taxable_value + gst_value - debit_notes + credit_notes - advances - tds_estimate AS net_payable
    FROM #r ORDER BY last_received_date, po_basic_sno;
END
