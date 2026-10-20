-- ============================================================
-- 62_tds_applies_to.sql   (Non_trade_Dev)
-- Each TDS section is tagged with what it applies to: 'Service', 'Product' or 'Both'.
-- The master groups sections by it, and the Payment screen offers only the sections that fit the bill
-- (service bill -> Service + Both, goods bill -> Product + Both, a mix of the two -> all).
-- Re-runnable.
-- ============================================================
IF COL_LENGTH('dbo.tds_section_master', 'applies_to') IS NULL
    ALTER TABLE dbo.tds_section_master ADD applies_to VARCHAR(7) NOT NULL CONSTRAINT DF_tds_applies_to DEFAULT 'Both';
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_tds_applies_to')
    ALTER TABLE dbo.tds_section_master ADD CONSTRAINT CK_tds_applies_to CHECK (applies_to IN ('Service', 'Product', 'Both'));
GO
-- first-time classification of the seeded sections (only rows still on the default)
UPDATE dbo.tds_section_master SET applies_to = 'Service'
 WHERE applies_to = 'Both' AND section_code IN ('194C', '194J', '194J-T', '194I', '194I-PM', '194H', '194M', '194D', '194T');
UPDATE dbo.tds_section_master SET applies_to = 'Product'
 WHERE applies_to = 'Both' AND section_code IN ('194Q', '194IA', '194S', '194LA');
GO
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetTdsSections
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT section_code, description, rate_individual, rate_other, rate_no_pan, single_threshold, annual_threshold,
           excess_only, is_goods_default, applies_to, is_active, modified_by, CONVERT(VARCHAR(19), modified_at, 120) AS modified_at
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
            @ap VARCHAR(7) = JSON_VALUE(@jsonInput, '$.applies_to'),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.modified_by');
    IF @ap IS NOT NULL AND @ap NOT IN ('Service', 'Product', 'Both') THROW 53503, 'applies_to must be Service, Product or Both.', 1;
    IF EXISTS (SELECT 1 FROM dbo.tds_section_master WHERE section_code = @c)
        UPDATE dbo.tds_section_master SET
            description = ISNULL(@d, description), rate_individual = ISNULL(@ri, rate_individual), rate_other = ISNULL(@ro, rate_other),
            rate_no_pan = ISNULL(@rn, rate_no_pan), single_threshold = ISNULL(@st, single_threshold), annual_threshold = ISNULL(@at, annual_threshold),
            excess_only = ISNULL(@ex, excess_only), applies_to = ISNULL(@ap, applies_to), is_active = ISNULL(@ac, is_active), modified_by = @by, modified_at = GETDATE()
        WHERE section_code = @c;
    ELSE
    BEGIN
        IF @d IS NULL OR @ri IS NULL OR @ro IS NULL THROW 53502, 'description, rate_individual and rate_other are required for a new section.', 1;
        INSERT INTO dbo.tds_section_master (section_code, description, rate_individual, rate_other, rate_no_pan, single_threshold, annual_threshold, excess_only, applies_to, is_active, modified_by)
        VALUES (@c, @d, @ri, @ro, ISNULL(@rn, 20), ISNULL(@st, 0), ISNULL(@at, 0), ISNULL(@ex, 'N'), ISNULL(@ap, 'Both'), ISNULL(@ac, 'Y'), @by);
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
