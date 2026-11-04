-- ============================================================
-- 74_payment_group.sql   (Non_trade_Dev ONLY, re-runnable, NOT APPLIED until the user OKs it)
--
-- A payment GROUP: when one Save on the Payment screen pays several suppliers of the SAME company / division / branch, the
-- per-supplier payments are tied together under one group record (PG-yyyy-nnnnnn) so they show, are approved and are paid as one:
--   payment_group        header: number, company/division/branch, how many payments, total
--   payment_info.group_sno  which group a payment belongs to (NULL = a stand-alone payment, as before)
--
-- Each payment keeps its own supplier, invoices, TDS, approval chain and bank-file line - the group changes none of that. The
-- screens use it to approve every payment of the group in one action and to tick the whole group in Payment Run, which already
-- makes ONE run + ONE file per company/division/branch.
--
--   sp_nt_CreatePaymentGroup  ties >= 2 saved payments of one company/division/branch into a group
--   sp_nt_GetPaymentGroupMap  payment_sno -> group for the screens
--
-- Apply: cd grn-service && node sql/run_sql.mjs sql/74_payment_group.sql
-- Rollback: sql/backups/payment_group_2026-10-30_ROLLBACK.sql
-- ============================================================

IF OBJECT_ID('dbo.payment_group', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.payment_group (
        group_sno     INT IDENTITY(1,1) PRIMARY KEY,
        group_no      VARCHAR(30)  NOT NULL,
        com_sno       INT NULL,
        div_sno       INT NULL,
        brn_sno       INT NULL,
        payment_count INT NOT NULL,
        total_amount  DECIMAL(18,2) NOT NULL,
        is_active     CHAR(1) NOT NULL CONSTRAINT DF_payment_group_active DEFAULT 'Y',
        created_by    VARCHAR(30) NULL,
        created_date  DATETIME NOT NULL CONSTRAINT DF_payment_group_created DEFAULT GETDATE(),
        CONSTRAINT UQ_payment_group_no UNIQUE (group_no)
    );
END
GO

IF COL_LENGTH('dbo.payment_info', 'group_sno') IS NULL
    ALTER TABLE dbo.payment_info ADD group_sno INT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_payment_info_group')
    ALTER TABLE dbo.payment_info ADD CONSTRAINT FK_payment_info_group FOREIGN KEY (group_sno) REFERENCES dbo.payment_group (group_sno);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_payment_info_group' AND object_id = OBJECT_ID('dbo.payment_info'))
    CREATE INDEX IX_payment_info_group ON dbo.payment_info (group_sno) WHERE group_sno IS NOT NULL;
GO

-- { payment_snos: [..], created_by } -> the group row
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreatePaymentGroup
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @by VARCHAR(30) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.created_by'))), '');
    DECLARE @sel TABLE (payment_sno INT PRIMARY KEY);
    INSERT INTO @sel SELECT DISTINCT TRY_CAST(value AS INT) FROM OPENJSON(@jsonInput, '$.payment_snos');
    IF @by IS NULL THROW 57300, 'created_by is required.', 1;
    IF EXISTS (SELECT 1 FROM @sel WHERE payment_sno IS NULL) OR (SELECT COUNT(*) FROM @sel) < 2
        THROW 57301, 'A payment group needs at least two payments.', 1;

    IF (SELECT COUNT(*) FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno AND pi.is_active = 'Y') <> (SELECT COUNT(*) FROM @sel)
        THROW 57302, 'One of the payments was not found.', 1;
    IF EXISTS (SELECT 1 FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno WHERE pi.status NOT IN ('Pending Approval', 'Approved') OR pi.batch_sno IS NOT NULL)
        THROW 57303, 'Only payments that are waiting for approval or for the payment run can be grouped.', 1;
    IF EXISTS (SELECT 1 FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno WHERE pi.group_sno IS NOT NULL)
        THROW 57304, 'A payment is already in a group.', 1;
    IF (SELECT COUNT(*) FROM (SELECT DISTINCT ISNULL(pi.com_sno, -1) c, ISNULL(pi.div_sno, -1) d, ISNULL(pi.brn_sno, -1) b
                              FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno) x) > 1
        THROW 57305, 'A payment group covers one company, division and branch.', 1;

    DECLARE @gsno INT, @gno VARCHAR(30), @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
    DECLARE @own_tran BIT = IIF(@@TRANCOUNT = 0, 1, 0);
    BEGIN TRY
        IF @own_tran = 1 BEGIN TRANSACTION;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(group_no, 6) AS INT)), 0) + 1 FROM dbo.payment_group WITH (UPDLOCK, HOLDLOCK) WHERE group_no LIKE 'PG-' + @year + '-%';
        SET @gno = 'PG-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);
        INSERT INTO dbo.payment_group (group_no, com_sno, div_sno, brn_sno, payment_count, total_amount, created_by)
        SELECT @gno, MIN(pi.com_sno), MIN(pi.div_sno), MIN(pi.brn_sno), COUNT(*), SUM(ISNULL(pi.net_paid, pi.amount)), @by
        FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno;
        SET @gsno = SCOPE_IDENTITY();
        UPDATE pi SET group_sno = @gsno FROM dbo.payment_info pi JOIN @sel s ON s.payment_sno = pi.payment_sno WHERE pi.group_sno IS NULL;
        IF @own_tran = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF @own_tran = 1 AND @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT group_sno, group_no, com_sno, div_sno, brn_sno, payment_count, total_amount, created_by, created_date
    FROM dbo.payment_group WHERE group_sno = @gsno;
END
GO

-- payment_sno -> group, for every grouped payment (the screens badge their rows with it)
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentGroupMap
AS
BEGIN
    SET NOCOUNT ON;
    SELECT pi.payment_sno, g.group_sno, g.group_no, g.payment_count
    FROM dbo.payment_info pi JOIN dbo.payment_group g ON g.group_sno = pi.group_sno
    WHERE pi.is_active = 'Y';
END
GO
