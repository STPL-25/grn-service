-- ============================================================
-- 58_grn_asset_tags.sql   (Non_trade_Dev)
-- Per-unit asset tags for approved GRNs: one unique tag code per accepted unit
-- (received_qty - rejected_qty, whole units) of every GRN line, printed as a QR label.
--   tag_code = AST-<grn_item_sno 5 digits>-<unit 3 digits>   e.g. AST-00045-003   (UNIQUE)
-- Generation is idempotent: re-running only adds units that have no tag yet.
-- Re-runnable.
-- ============================================================
IF OBJECT_ID('dbo.grn_asset_tags', 'U') IS NULL
CREATE TABLE dbo.grn_asset_tags (
    tag_sno        INT IDENTITY(1,1) PRIMARY KEY,
    tag_code       VARCHAR(30)  NOT NULL CONSTRAINT UQ_grn_asset_tags_code UNIQUE,
    grn_basic_sno  INT          NOT NULL,
    grn_item_sno   INT          NOT NULL,
    unit_no        INT          NOT NULL,
    prod_sno       INT          NULL,
    prod_name      NVARCHAR(255) NULL,
    created_by     VARCHAR(30)  NULL,
    created_at     DATETIME     NOT NULL DEFAULT GETDATE(),
    print_count    INT          NOT NULL DEFAULT 0,
    last_printed_at DATETIME    NULL,
    CONSTRAINT UQ_grn_asset_tags_item_unit UNIQUE (grn_item_sno, unit_no)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_grn_asset_tags_grn')
    CREATE INDEX IX_grn_asset_tags_grn ON dbo.grn_asset_tags (grn_basic_sno);
GO

-- approved GRNs with how many units / tags each has
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNsForAssetTags
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.grn_basic_sno,
           'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
           b.po_basic_sno, p.po_df_no AS po_no, k.company_name AS vendor_name,
           CONVERT(VARCHAR(10), b.received_date, 120) AS received_date,
           CONVERT(VARCHAR(30), b.approved_at, 120) AS approved_at,
           b.com_sno, b.div_sno, b.brn_sno, b.dept_sno,
           (SELECT COUNT(*) FROM dbo.grn_item_details gi WHERE gi.grn_basic_sno = b.grn_basic_sno AND gi.is_active = 'Y') AS item_count,
           (SELECT ISNULL(SUM(CASE WHEN gi.received_qty - ISNULL(gi.rejected_qty, 0) >= 1
                                   THEN CAST(FLOOR(gi.received_qty - ISNULL(gi.rejected_qty, 0)) AS INT) ELSE 0 END), 0)
              FROM dbo.grn_item_details gi WHERE gi.grn_basic_sno = b.grn_basic_sno AND gi.is_active = 'Y') AS unit_count,
           (SELECT COUNT(*) FROM dbo.grn_asset_tags t WHERE t.grn_basic_sno = b.grn_basic_sno) AS tag_count
    FROM dbo.grn_basic_info b
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = b.vendor_sno
    WHERE b.is_active = 'Y' AND b.status IN ('Approved', 'Received')
    ORDER BY b.grn_basic_sno DESC;
END
GO

-- creates the missing tags of one GRN (max 1000 units per line) and returns all its tags
-- @jsonInput: { grn_basic_sno, created_by }
CREATE OR ALTER PROCEDURE dbo.sp_nt_GenerateGRNAssetTags
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.grn_basic_sno') AS INT),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by');
    IF @grn IS NULL THROW 53301, 'grn_basic_sno is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.grn_basic_info WHERE grn_basic_sno = @grn AND is_active = 'Y' AND status IN ('Approved', 'Received'))
        THROW 53302, 'Asset tags can be generated only for an approved GRN.', 1;

    ;WITH n AS (SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS u FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT INTO dbo.grn_asset_tags (tag_code, grn_basic_sno, grn_item_sno, unit_no, prod_sno, prod_name, created_by)
    SELECT 'AST-' + RIGHT('00000' + CAST(gi.grn_item_sno AS VARCHAR(10)), 5) + '-' + RIGHT('000' + CAST(n.u AS VARCHAR(4)), 3),
           gi.grn_basic_sno, gi.grn_item_sno, n.u, gi.prod_sno, gi.prod_name, @by
    FROM dbo.grn_item_details gi
    JOIN n ON n.u <= FLOOR(gi.received_qty - ISNULL(gi.rejected_qty, 0))
    WHERE gi.grn_basic_sno = @grn AND gi.is_active = 'Y'
      AND NOT EXISTS (SELECT 1 FROM dbo.grn_asset_tags t WHERE t.grn_item_sno = gi.grn_item_sno AND t.unit_no = n.u);

    EXEC dbo.sp_nt_GetGRNAssetTags @jsonInput = @jsonInput;
END
GO

-- one row per tag, with the line it belongs to
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNAssetTags
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.grn_basic_sno') AS INT);
    SELECT t.tag_sno, t.tag_code, t.grn_basic_sno, t.grn_item_sno, t.unit_no, t.prod_sno, t.prod_name,
           gi.specification, gi.unit_name, gi.hsn_code,
           pm.prod_code, CONVERT(VARCHAR(10), b.received_date, 120) AS grn_date, bm.brn_name AS asset_branch,
           CAST(FLOOR(gi.received_qty - ISNULL(gi.rejected_qty, 0)) AS INT) AS item_units,
           t.print_count, CONVERT(VARCHAR(30), t.last_printed_at, 120) AS last_printed_at
    FROM dbo.grn_asset_tags t
    JOIN dbo.grn_item_details gi ON gi.grn_item_sno = t.grn_item_sno
    JOIN dbo.grn_basic_info b ON b.grn_basic_sno = t.grn_basic_sno
    LEFT JOIN dbo.product_master pm ON pm.prod_sno = t.prod_sno
    LEFT JOIN dbo.branch_master bm ON bm.brn_sno = b.brn_sno
    WHERE t.grn_basic_sno = @grn
    ORDER BY t.grn_item_sno, t.unit_no;
END
GO

-- @jsonInput: { tag_codes: ["AST-00045-001", ...] }
CREATE OR ALTER PROCEDURE dbo.sp_nt_MarkAssetTagsPrinted
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE t SET print_count = print_count + 1, last_printed_at = GETDATE()
    FROM dbo.grn_asset_tags t
    WHERE t.tag_code IN (SELECT [value] FROM OPENJSON(@jsonInput, '$.tag_codes'));
    SELECT @@ROWCOUNT AS updated;
END
GO

-- screen + grant to KTM1148
IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'GRNAssetTagsPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    SELECT N'GRN Asset Tags', screen_code, 'GRNAssetTagsPage', 'QrCode', group_id, display_order + 2, 'Y'
    FROM dbo.screens WHERE comp = 'GRNPage';
GO
DECLARE @sid INT = (SELECT TOP 1 screen_id FROM dbo.screens WHERE comp = 'GRNAssetTagsPage');
DECLARE @json NVARCHAR(MAX) = (SELECT 'KTM1148' AS ecno, @sid AS screen_id,
                                      JSON_QUERY('[2,3,4,5,7,8]') AS permission_ids FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
GO

-- Print-once: atomically claims the tags that have never been printed and returns only those codes.
-- A tag already printed is never returned again, so it cannot be printed a second time.
-- @jsonInput: { tag_codes: [...] }
CREATE OR ALTER PROCEDURE dbo.sp_nt_ClaimAssetTagsForPrint
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE t SET print_count = print_count + 1, last_printed_at = GETDATE()
    OUTPUT inserted.tag_code
    FROM dbo.grn_asset_tags t
    WHERE t.print_count = 0
      AND t.tag_code IN (SELECT [value] FROM OPENJSON(@jsonInput, '$.tag_codes'));
END
GO
