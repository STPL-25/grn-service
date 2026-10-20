-- ============================================================
-- 60_tds_master_screen.sql   (Non_trade_Dev)
-- Backs the TDS Section master screen (Masters > TDS Section):
--   sp_nt_GetTdsSections  - every section incl. inactive + the goods-default flag
--   sp_nt_UpsertTdsSection - now also sets is_goods_default (only one section can be the default)
-- Re-runnable.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetTdsSections
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT section_code, description, rate_individual, rate_other, rate_no_pan, single_threshold, annual_threshold,
           excess_only, is_goods_default, is_active, modified_by, CONVERT(VARCHAR(19), modified_at, 120) AS modified_at
    FROM dbo.tds_section_master ORDER BY section_code;
END
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpsertTdsSection
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @c VARCHAR(10) = UPPER(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.section_code'))), ''));
    IF @c IS NULL THROW 53501, 'section_code is required.', 1;
    DECLARE @d NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.description'),
            @ri DECIMAL(6,3) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_individual') AS DECIMAL(6,3)),
            @ro DECIMAL(6,3) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_other') AS DECIMAL(6,3)),
            @rn DECIMAL(6,3) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_no_pan') AS DECIMAL(6,3)),
            @st DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.single_threshold') AS DECIMAL(18,2)),
            @at DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.annual_threshold') AS DECIMAL(18,2)),
            @ex CHAR(1) = JSON_VALUE(@jsonInput, '$.excess_only'),
            @ac CHAR(1) = JSON_VALUE(@jsonInput, '$.is_active'),
            @gd CHAR(1) = JSON_VALUE(@jsonInput, '$.is_goods_default'),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.modified_by');
    IF EXISTS (SELECT 1 FROM dbo.tds_section_master WHERE section_code = @c)
        UPDATE dbo.tds_section_master SET
            description = ISNULL(@d, description), rate_individual = ISNULL(@ri, rate_individual), rate_other = ISNULL(@ro, rate_other),
            rate_no_pan = ISNULL(@rn, rate_no_pan), single_threshold = ISNULL(@st, single_threshold), annual_threshold = ISNULL(@at, annual_threshold),
            excess_only = ISNULL(@ex, excess_only), is_active = ISNULL(@ac, is_active), modified_by = @by, modified_at = GETDATE()
        WHERE section_code = @c;
    ELSE
    BEGIN
        IF @d IS NULL OR @ri IS NULL OR @ro IS NULL THROW 53502, 'description, rate_individual and rate_other are required for a new section.', 1;
        INSERT INTO dbo.tds_section_master (section_code, description, rate_individual, rate_other, rate_no_pan, single_threshold, annual_threshold, excess_only, is_active, modified_by)
        VALUES (@c, @d, @ri, @ro, ISNULL(@rn, 20), ISNULL(@st, 0), ISNULL(@at, 0), ISNULL(@ex, 'N'), ISNULL(@ac, 'Y'), @by);
    END
    IF @gd = 'Y'
    BEGIN
        UPDATE dbo.tds_section_master SET is_goods_default = 'N' WHERE section_code <> @c AND is_goods_default = 'Y';
        UPDATE dbo.tds_section_master SET is_goods_default = 'Y' WHERE section_code = @c;
    END
    ELSE IF @gd = 'N'
        UPDATE dbo.tds_section_master SET is_goods_default = 'N' WHERE section_code = @c;
    SELECT * FROM dbo.tds_section_master WHERE section_code = @c;
END
GO
