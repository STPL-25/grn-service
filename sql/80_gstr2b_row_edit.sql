-- ============================================================
-- 80_gstr2b_row_edit.sql   (Non_trade_Dev ONLY)
--
-- GSTR-2B reconciliation: edit a 2B row that did not match (typo in the invoice no / GSTIN / amounts,
-- or a skipped row that should be looked at again) and re-run the match for it.
--   * Editable while match_status is Unmatched, Mismatch or Skipped. Matched / Added rows already changed the books -> locked.
--   * After the edit the row goes back to 'New' and sp_nt_Gstr2bMatch runs again, so it lands in Matched / Mismatch / Unmatched.
-- Re-runnable.
-- ============================================================

-- { row_sno, supplier_gstin, trade_name, invoice_no, invoice_date, invoice_value, taxable_value, igst, cgst, sgst, cess, by }
CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bEditRow
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @row INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.row_sno') AS INT),
            @gstin VARCHAR(20) = UPPER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.supplier_gstin')))),
            @trade NVARCHAR(200) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.trade_name'))), ''),
            @ino NVARCHAR(100) = LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.invoice_no'))),
            @idate DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_date') AS DATE),
            @ival DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_value') AS DECIMAL(18,2)),
            @tx DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.taxable_value') AS DECIMAL(18,2)),
            @ig DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.igst') AS DECIMAL(18,2)), 0),
            @cg DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.cgst') AS DECIMAL(18,2)), 0),
            @sg DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.sgst') AS DECIMAL(18,2)), 0),
            @cess DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.cess') AS DECIMAL(18,2)), 0),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.by'),
            @status VARCHAR(10), @u INT;

    SELECT @status = match_status, @u = upload_sno FROM dbo.gstr2b_row WHERE row_sno = @row;
    IF @status IS NULL THROW 53630, 'Row not found.', 1;
    IF @status NOT IN ('Unmatched', 'Mismatch', 'Skipped') THROW 53631, 'Only rows that are not matched (Not in books, Mismatch or Skipped) can be edited.', 1;
    IF @gstin IS NULL OR LEN(@gstin) <> 15 THROW 53632, 'Supplier GSTIN must be 15 characters.', 1;
    IF NULLIF(@ino, '') IS NULL THROW 53633, 'Invoice number is required.', 1;
    IF @ival IS NULL OR @ival < 0 OR @tx IS NULL OR @tx < 0 THROW 53634, 'Invoice value and taxable value must be zero or more.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        UPDATE dbo.gstr2b_row SET
            supplier_gstin = @gstin, trade_name = ISNULL(@trade, trade_name), invoice_no = @ino, norm_invoice_no = dbo.fn_nt_NormInvoiceNo(@ino),
            invoice_date = @idate, invoice_value = @ival, taxable_value = @tx, igst = @ig, cgst = @cg, sgst = @sg, cess = @cess,
            match_status = 'New', books_invoice_sno = NULL, mismatch_note = NULL, acted_by = @by, acted_at = GETDATE()
        WHERE row_sno = @row;

        EXEC dbo.sp_nt_Gstr2bMatch @upload_sno = @u, @by = @by;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    SELECT row_sno, match_status, books_invoice_sno, mismatch_note FROM dbo.gstr2b_row WHERE row_sno = @row;
END
GO
