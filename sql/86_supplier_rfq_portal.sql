/*
  86_supplier_rfq_portal.sql  -  Supplier portal side of the Request For Quotation flow.

  Needs backend-stpl/sql/154_rfq.sql first (it creates the rfq_* tables these procedures read and write).

  The supplier logs in to the portal (nt_supplier_login), sees the RFQs addressed to it, fills in the rates on the
  Quotation Entry screen and submits. Submitting again (because rates changed, or the buyer asked for a revision)
  stores a NEW version; earlier versions stay untouched so the buyer can compare them and take any one as the final
  quotation. A supplier only ever sees its own RFQ rows - every procedure checks rfq_supplier.vendor_sno.

  Dates go out as 'yyyy-mm-dd' / 'yyyy-mm-dd hh:mi:ss' strings (same as the other portal procedures) so the browser does
  not shift them by the UTC offset.

  Idempotent: safe to run more than once.  Apply to Non_trade_Dev only.
*/

-- The RFQs addressed to one supplier. {kyc_basic_info_sno}
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetRfqsForSupplier
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @k INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno') AS INT);

    SELECT rs.rfq_supplier_sno, r.rfq_no, com.com_name,
           CONVERT(VARCHAR(10), ISNULL(rs.response_due_date, r.response_due_date), 23) AS due_date,
           r.notes, rs.status, r.status AS rfq_status, rs.response_count, rs.revision_note,
           cur.version_no AS current_version, cur.grand_total,
           CONVERT(VARCHAR(19), cur.submitted_at, 120) AS last_submitted_at,
           CONVERT(VARCHAR(19), r.created_at, 120) AS requested_at,
           (SELECT COUNT(*) FROM dbo.rfq_item ri WHERE ri.rfq_sno = r.rfq_sno AND ri.is_active = 'Y') AS item_count,
           CAST(CASE WHEN r.status = 'O'
                      AND rs.status IN ('PENDING', 'VIEWED', 'SUBMITTED', 'REVISION_REQUESTED', 'DECLINED')
                      AND CAST(GETDATE() AS DATE) <= ISNULL(rs.response_due_date, r.response_due_date)
                     THEN 1 ELSE 0 END AS BIT) AS can_respond
    FROM dbo.rfq_supplier rs
    JOIN dbo.rfq_info r ON r.rfq_sno = rs.rfq_sno AND r.is_active = 'Y'
    LEFT JOIN dbo.company_master com ON com.com_sno = r.com_sno
    LEFT JOIN dbo.rfq_response cur ON cur.rfq_response_sno = rs.current_response_sno
    WHERE rs.vendor_sno = @k
    ORDER BY r.rfq_sno DESC;
END
GO

-- One RFQ for the Quotation Entry screen (opening it marks it Viewed). {kyc_basic_info_sno, rfq_supplier_sno}
-- Result sets: 1 header, 2 items (with the supplier's latest prices), 3 latest response header, 4 version history,
--              5 payment-terms choices.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetRfqDetailForSupplier
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @k INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno') AS INT),
            @rs INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.rfq_supplier_sno') AS INT),
            @rfq_sno INT, @cur_resp INT, @first_view DATETIME;

    SELECT @rfq_sno = r.rfq_sno, @cur_resp = rs.current_response_sno, @first_view = rs.first_viewed_at
    FROM dbo.rfq_supplier rs JOIN dbo.rfq_info r ON r.rfq_sno = rs.rfq_sno AND r.is_active = 'Y'
    WHERE rs.rfq_supplier_sno = @rs AND rs.vendor_sno = @k;
    IF @rfq_sno IS NULL THROW 53160, N'Quotation request not found.', 1;

    IF @first_view IS NULL
    BEGIN
        BEGIN TRAN;
        UPDATE dbo.rfq_supplier
        SET first_viewed_at = GETDATE(), status = CASE WHEN status = 'PENDING' THEN 'VIEWED' ELSE status END
        WHERE rfq_supplier_sno = @rs;
        INSERT INTO dbo.rfq_supplier_log (rfq_sno, rfq_supplier_sno, event_type, event_by, event_note)
        VALUES (@rfq_sno, @rs, 'VIEWED', CONCAT(N'supplier #', @k), N'Supplier opened the request');
        COMMIT;
    END

    -- 1. header
    SELECT rs.rfq_supplier_sno, r.rfq_no, com.com_name, r.notes, rs.status, r.status AS rfq_status,
           CONVERT(VARCHAR(10), ISNULL(rs.response_due_date, r.response_due_date), 23) AS due_date,
           rs.revision_note, rs.decline_reason, rs.response_count, cur.version_no AS current_version,
           CONVERT(VARCHAR(19), r.created_at, 120) AS requested_at,
           CAST(CASE WHEN r.status = 'O'
                      AND rs.status IN ('PENDING', 'VIEWED', 'SUBMITTED', 'REVISION_REQUESTED', 'DECLINED')
                      AND CAST(GETDATE() AS DATE) <= ISNULL(rs.response_due_date, r.response_due_date)
                     THEN 1 ELSE 0 END AS BIT) AS can_respond
    FROM dbo.rfq_supplier rs
    JOIN dbo.rfq_info r ON r.rfq_sno = rs.rfq_sno
    LEFT JOIN dbo.company_master com ON com.com_sno = r.com_sno
    LEFT JOIN dbo.rfq_response cur ON cur.rfq_response_sno = rs.current_response_sno
    WHERE rs.rfq_supplier_sno = @rs;

    -- 2. items + the prices of the latest submitted version (blank when nothing was submitted yet)
    SELECT ri.rfq_item_sno, ri.prod_sno, pm.prod_name, ri.specification, ri.qty, ri.unit, um.uom_name AS unit_name,
           ISNULL(cri.is_quoted, 1) AS is_quoted, ISNULL(cri.unit_price, 0) AS unit_price, ISNULL(cri.discount_pct, 0) AS discount_pct,
           ISNULL(cri.tax_pct, 0) AS tax_pct, ISNULL(cri.total_amount, 0) AS total_amount, cri.delivery_days, cri.remarks,
           cri.additional_json
    FROM dbo.rfq_item ri
    LEFT JOIN dbo.product_master pm ON pm.prod_sno = ri.prod_sno
    LEFT JOIN dbo.uom_master um ON um.uom_sno = ri.unit
    LEFT JOIN dbo.rfq_response_item cri ON cri.rfq_response_sno = @cur_resp AND cri.rfq_item_sno = ri.rfq_item_sno
    WHERE ri.rfq_sno = @rfq_sno AND ri.is_active = 'Y'
    ORDER BY ri.rfq_item_sno;

    -- 3. latest response header (0 or 1 row) - pre-fills the form for a re-submission
    SELECT resp.rfq_response_sno, resp.version_no, resp.quotation_ref_no,
           CONVERT(VARCHAR(10), resp.quotation_date, 23) AS quotation_date, CONVERT(VARCHAR(10), resp.valid_upto, 23) AS valid_upto,
           resp.currency_code, resp.payment_terms, resp.delivery_days, resp.remarks,
           resp.freight_charges, resp.freight_gst_pct, resp.other_charges, resp.other_charges_gst_pct,
           resp.items_total, resp.grand_total, resp.quotation_file, CONVERT(VARCHAR(19), resp.submitted_at, 120) AS submitted_at
    FROM dbo.rfq_response resp WHERE resp.rfq_response_sno = @cur_resp;

    -- 4. version history
    SELECT resp.version_no, CONVERT(VARCHAR(19), resp.submitted_at, 120) AS submitted_at, resp.grand_total,
           CONVERT(VARCHAR(10), resp.valid_upto, 23) AS valid_upto, resp.change_note, resp.quotation_file
    FROM dbo.rfq_response resp WHERE resp.rfq_supplier_sno = @rs ORDER BY resp.version_no DESC;

    -- 5. payment-terms master
    SELECT payment_terms_name FROM dbo.payment_terms_master WHERE is_active = 'Y' ORDER BY payment_terms_name;
END
GO

-- Stores a submission as the next version.
-- {kyc_basic_info_sno, rfq_supplier_sno, quotation_ref_no?, quotation_date?, valid_upto, currency_code?, payment_terms?,
--  delivery_days?, remarks?, change_note (required from v2), freight_charges?, freight_gst_pct?, other_charges?,
--  other_charges_gst_pct?, quotation_file?, submitted_by, items:[{rfq_item_sno, is_quoted, unit_price, discount_pct,
--  tax_pct, delivery_days, remarks, additional:[...]}]}
CREATE OR ALTER PROCEDURE dbo.sp_nt_SubmitRfqResponse
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF ISJSON(@jsonInput) <> 1 THROW 53170, N'Invalid JSON input.', 1;

    DECLARE @k INT   = TRY_CAST(JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno') AS INT),
            @rs INT  = TRY_CAST(JSON_VALUE(@jsonInput, '$.rfq_supplier_sno') AS INT),
            @ref VARCHAR(50) = NULLIF(LTRIM(RTRIM(LEFT(JSON_VALUE(@jsonInput, '$.quotation_ref_no'), 50))), ''),
            @qdate DATE = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.quotation_date') AS DATE), CAST(GETDATE() AS DATE)),
            @valid DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.valid_upto') AS DATE),
            @cur VARCHAR(10) = ISNULL(NULLIF(LEFT(JSON_VALUE(@jsonInput, '$.currency_code'), 10), ''), 'INR'),
            @terms NVARCHAR(200) = NULLIF(LTRIM(RTRIM(LEFT(JSON_VALUE(@jsonInput, '$.payment_terms'), 200))), ''),
            @days INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.delivery_days') AS INT),
            @remarks NVARCHAR(200) = NULLIF(LTRIM(RTRIM(LEFT(JSON_VALUE(@jsonInput, '$.remarks'), 200))), ''),
            @change NVARCHAR(500) = NULLIF(LTRIM(RTRIM(LEFT(JSON_VALUE(@jsonInput, '$.change_note'), 500))), ''),
            @fr DECIMAL(18,2)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.freight_charges') AS DECIMAL(18,2)), 0),
            @frg DECIMAL(9,3)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.freight_gst_pct') AS DECIMAL(9,3)), 0),
            @oc DECIMAL(18,2)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.other_charges') AS DECIMAL(18,2)), 0),
            @ocg DECIMAL(9,3)  = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.other_charges_gst_pct') AS DECIMAL(9,3)), 0),
            @file NVARCHAR(500) = NULLIF(JSON_VALUE(@jsonInput, '$.quotation_file'), ''),
            @by VARCHAR(255) = NULLIF(JSON_VALUE(@jsonInput, '$.submitted_by'), ''),
            @rfq_sno INT, @rfq_status CHAR(1), @status VARCHAR(20), @eff_due DATE, @rfq_no VARCHAR(30), @created_by VARCHAR(20),
            @company NVARCHAR(100), @pr_no VARCHAR(50), @prev_file NVARCHAR(500), @resp INT, @ver INT;

    IF @k IS NULL OR @rs IS NULL THROW 53171, N'Missing supplier or request.', 1;

    SELECT @rfq_sno = r.rfq_sno, @rfq_status = r.status, @status = rs.status, @eff_due = ISNULL(rs.response_due_date, r.response_due_date),
           @rfq_no = r.rfq_no, @created_by = r.created_by, @company = k.company_name, @pr_no = r.pr_no
    FROM dbo.rfq_supplier rs
    JOIN dbo.rfq_info r ON r.rfq_sno = rs.rfq_sno AND r.is_active = 'Y'
    JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = rs.vendor_sno
    WHERE rs.rfq_supplier_sno = @rs AND rs.vendor_sno = @k;

    IF @rfq_sno IS NULL THROW 53172, N'Quotation request not found.', 1;
    IF @rfq_status <> 'O' OR @status = 'CLOSED' THROW 53173, N'This request has been closed by the purchase team.', 1;
    IF @status = 'TAKEN' THROW 53174, N'Your quotation has already been accepted, so it can no longer be changed. Please contact the purchase team.', 1;
    IF CAST(GETDATE() AS DATE) > @eff_due THROW 53175, N'The response due date for this request has passed. Please contact the purchase team to reopen it.', 1;

    IF @valid IS NULL THROW 53176, N'Enter how long your quotation is valid (Valid until).', 1;
    IF @valid < @qdate THROW 53177, N'Valid until cannot be before the quotation date.', 1;
    IF @fr < 0 OR @oc < 0 THROW 53178, N'Freight / other charges cannot be negative.', 1;
    IF @frg < 0 OR @frg > 100 OR @ocg < 0 OR @ocg > 100 THROW 53179, N'GST % on charges must be between 0 and 100.', 1;
    IF @days IS NOT NULL AND @days < 0 THROW 53180, N'Delivery days cannot be negative.', 1;

    DECLARE @in TABLE (rfq_item_sno INT PRIMARY KEY, is_quoted BIT, unit_price DECIMAL(18,4), discount_pct DECIMAL(9,3), tax_pct DECIMAL(9,3),
                       delivery_days INT, remarks NVARCHAR(200), additional NVARCHAR(MAX));
    INSERT INTO @in (rfq_item_sno, is_quoted, unit_price, discount_pct, tax_pct, delivery_days, remarks, additional)
    SELECT rfq_item_sno, ISNULL(is_quoted, 1), ISNULL(unit_price, 0), ISNULL(discount_pct, 0), ISNULL(tax_pct, 0), delivery_days,
           LEFT(remarks, 200), additional
    FROM OPENJSON(@jsonInput, '$.items')
    WITH (rfq_item_sno INT '$.rfq_item_sno', is_quoted BIT '$.is_quoted', unit_price DECIMAL(18,4) '$.unit_price',
          discount_pct DECIMAL(9,3) '$.discount_pct', tax_pct DECIMAL(9,3) '$.tax_pct', delivery_days INT '$.delivery_days',
          remarks NVARCHAR(1000) '$.remarks', additional NVARCHAR(MAX) '$.additional' AS JSON);

    IF EXISTS (SELECT 1 FROM @in i WHERE NOT EXISTS (SELECT 1 FROM dbo.rfq_item ri WHERE ri.rfq_item_sno = i.rfq_item_sno AND ri.rfq_sno = @rfq_sno AND ri.is_active = 'Y'))
        THROW 53181, N'The quotation contains an item that is not part of this request.', 1;
    IF NOT EXISTS (SELECT 1 FROM @in WHERE is_quoted = 1 AND unit_price > 0)
        THROW 53182, N'Quote a price for at least one item.', 1;
    IF EXISTS (SELECT 1 FROM @in WHERE is_quoted = 1 AND unit_price <= 0)
        THROW 53183, N'Enter a unit price for every item you quote - or untick the items you are not quoting.', 1;
    IF EXISTS (SELECT 1 FROM @in WHERE discount_pct < 0 OR discount_pct > 100 OR tax_pct < 0 OR tax_pct > 100)
        THROW 53184, N'Discount % and GST % must be between 0 and 100.', 1;
    IF EXISTS (SELECT 1 FROM @in WHERE delivery_days < 0) THROW 53185, N'Delivery days cannot be negative.', 1;

    SELECT @ver = ISNULL(MAX(version_no), 0) + 1 FROM dbo.rfq_response WHERE rfq_supplier_sno = @rs;
    IF @ver > 1 AND @change IS NULL THROW 53186, N'Tell us what changed since your previous submission.', 1;
    IF @ref IS NULL SET @ref = LEFT(@rfq_no + '-V' + CAST(@ver AS VARCHAR(5)), 50);

    -- a re-submission without a new document keeps the document of the previous version
    IF @file IS NULL
        SELECT TOP 1 @file = quotation_file FROM dbo.rfq_response WHERE rfq_supplier_sno = @rs AND quotation_file IS NOT NULL ORDER BY version_no DESC;

    BEGIN TRAN;

    UPDATE dbo.rfq_response SET is_current = 'N' WHERE rfq_supplier_sno = @rs AND is_current = 'Y';

    INSERT INTO dbo.rfq_response (rfq_supplier_sno, rfq_sno, version_no, quotation_ref_no, quotation_date, valid_upto, currency_code, payment_terms,
                                  delivery_days, remarks, change_note, freight_charges, freight_gst_pct, other_charges, other_charges_gst_pct,
                                  quotation_file, is_current, submitted_by)
    VALUES (@rs, @rfq_sno, @ver, @ref, @qdate, @valid, @cur, @terms, @days, @remarks, @change, @fr, @frg, @oc, @ocg, @file, 'Y', @by);
    SET @resp = SCOPE_IDENTITY();

    INSERT INTO dbo.rfq_response_item (rfq_response_sno, rfq_item_sno, pr_item_sno, prod_sno, specification, qty, unit, is_quoted, unit_price,
                                       discount_pct, tax_pct, total_amount, delivery_days, remarks, additional_json)
    SELECT @resp, ri.rfq_item_sno, ri.pr_item_sno, ri.prod_sno, ri.specification, ri.qty, ri.unit,
           CASE WHEN i.is_quoted = 1 AND i.unit_price > 0 THEN 1 ELSE 0 END,
           CASE WHEN i.is_quoted = 1 AND i.unit_price > 0 THEN i.unit_price ELSE 0 END,
           CASE WHEN i.is_quoted = 1 AND i.unit_price > 0 THEN i.discount_pct ELSE 0 END,
           CASE WHEN i.is_quoted = 1 AND i.unit_price > 0 THEN i.tax_pct ELSE 0 END,
           CASE WHEN i.is_quoted = 1 AND i.unit_price > 0
                THEN ROUND(ri.qty * i.unit_price * (1 - i.discount_pct / 100.0) * (1 + i.tax_pct / 100.0), 2) ELSE 0 END,
           i.delivery_days, i.remarks,
           CASE WHEN i.is_quoted = 1 AND ISJSON(i.additional) = 1 AND i.additional <> N'[]' THEN i.additional END
    FROM dbo.rfq_item ri
    LEFT JOIN @in i ON i.rfq_item_sno = ri.rfq_item_sno
    WHERE ri.rfq_sno = @rfq_sno AND ri.is_active = 'Y';

    UPDATE dbo.rfq_response
    SET items_total = (SELECT ISNULL(SUM(total_amount), 0) FROM dbo.rfq_response_item WHERE rfq_response_sno = @resp AND is_quoted = 1)
    WHERE rfq_response_sno = @resp;
    UPDATE dbo.rfq_response
    SET grand_total = items_total + ROUND(freight_charges * (1 + freight_gst_pct / 100.0), 2) + ROUND(other_charges * (1 + other_charges_gst_pct / 100.0), 2)
    WHERE rfq_response_sno = @resp;

    UPDATE dbo.rfq_supplier
    SET status = 'SUBMITTED', response_count = @ver, current_response_sno = @resp, revision_note = NULL, decline_reason = NULL,
        first_viewed_at = ISNULL(first_viewed_at, GETDATE())
    WHERE rfq_supplier_sno = @rs;

    INSERT INTO dbo.rfq_supplier_log (rfq_sno, rfq_supplier_sno, event_type, event_by, event_note)
    VALUES (@rfq_sno, @rs, 'SUBMITTED', @by, LEFT(CASE WHEN @ver = 1 THEN N'Quotation submitted (v1)' ELSE CONCAT(N'Revised quotation submitted (v', @ver, N'): ', @change) END, 500));

    COMMIT;

    SELECT @resp AS rfq_response_sno, @ver AS version_no, grand_total, @rfq_no AS rfq_no, @created_by AS created_by,
           @company AS company_name, @pr_no AS pr_no, @rs AS rfq_supplier_sno
    FROM dbo.rfq_response WHERE rfq_response_sno = @resp;
END
GO

-- The supplier says it will not quote (or withdraws what it sent). {kyc_basic_info_sno, rfq_supplier_sno, reason, submitted_by?}
CREATE OR ALTER PROCEDURE dbo.sp_nt_DeclineRfq
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF ISJSON(@jsonInput) <> 1 THROW 53190, N'Invalid JSON input.', 1;

    DECLARE @k INT  = TRY_CAST(JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno') AS INT),
            @rs INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.rfq_supplier_sno') AS INT),
            @reason NVARCHAR(500) = NULLIF(LTRIM(RTRIM(LEFT(JSON_VALUE(@jsonInput, '$.reason'), 500))), ''),
            @by VARCHAR(255) = NULLIF(JSON_VALUE(@jsonInput, '$.submitted_by'), ''),
            @rfq_sno INT, @rfq_status CHAR(1), @status VARCHAR(20), @rfq_no VARCHAR(30), @created_by VARCHAR(20), @company NVARCHAR(100), @pr_no VARCHAR(50);

    IF @reason IS NULL THROW 53191, N'Please give a reason for declining.', 1;

    SELECT @rfq_sno = r.rfq_sno, @rfq_status = r.status, @status = rs.status, @rfq_no = r.rfq_no, @created_by = r.created_by,
           @company = k.company_name, @pr_no = r.pr_no
    FROM dbo.rfq_supplier rs
    JOIN dbo.rfq_info r ON r.rfq_sno = rs.rfq_sno AND r.is_active = 'Y'
    JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = rs.vendor_sno
    WHERE rs.rfq_supplier_sno = @rs AND rs.vendor_sno = @k;

    IF @rfq_sno IS NULL THROW 53192, N'Quotation request not found.', 1;
    IF @rfq_status <> 'O' OR @status = 'CLOSED' THROW 53193, N'This request has been closed by the purchase team.', 1;
    IF @status = 'TAKEN' THROW 53194, N'Your quotation has already been accepted, so it cannot be withdrawn here. Please contact the purchase team.', 1;
    IF @status = 'DECLINED' THROW 53195, N'You have already declined this request.', 1;

    BEGIN TRAN;
    UPDATE dbo.rfq_supplier SET status = 'DECLINED', decline_reason = @reason, revision_note = NULL,
           first_viewed_at = ISNULL(first_viewed_at, GETDATE())
    WHERE rfq_supplier_sno = @rs;
    INSERT INTO dbo.rfq_supplier_log (rfq_sno, rfq_supplier_sno, event_type, event_by, event_note)
    VALUES (@rfq_sno, @rs, 'DECLINED', @by, @reason);
    COMMIT;

    SELECT @rs AS rfq_supplier_sno, @rfq_no AS rfq_no, @created_by AS created_by, @company AS company_name, @pr_no AS pr_no;
END
GO
