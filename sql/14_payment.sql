-- ============================================================
-- Payment — releases funds against matched invoice_allocation_details buckets
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : new grn-service/src/payment module (port 8084, mounted at /api/payment)
--
-- payment_info/PaymentRecord field names are aligned to the existing frontend
-- mock types (nt-frontend-stpl/.../Payment/types.ts) to minimize the rewire:
-- mode: NEFT|RTGS|Cheque|Cash|UPI|DD, status: Pending|Processed|Cleared|Failed.
--
-- One payment can release multiple buckets across multiple invoices (e.g.
-- paying several matched allocation rows from different POs/vendors in one
-- bank transfer) via payment_allocation_details — each row is validated
-- against that bucket's release_amount minus whatever has already been paid
-- against it, so double-paying (or paying a still-held bucket) is rejected.
-- ============================================================

IF OBJECT_ID('dbo.payment_info', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.payment_info (
        payment_sno    INT IDENTITY(1,1) PRIMARY KEY,
        payment_no      VARCHAR(30)   NOT NULL UNIQUE,
        vendor_sno       INT           NULL,
        payment_date      DATE          NULL,
        amount             DECIMAL(18,2) NOT NULL DEFAULT 0,
        mode                VARCHAR(10)   NOT NULL,   -- NEFT | RTGS | Cheque | Cash | UPI | DD
        bank_account         VARCHAR(100)  NULL,
        reference_no          VARCHAR(100)  NULL,
        status                 VARCHAR(20)   NOT NULL DEFAULT 'Pending',  -- Pending | Processed | Cleared | Failed
        remarks                VARCHAR(500)  NULL,
        is_active                CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by                VARCHAR(20)   NULL,
        created_date               DATETIME      NOT NULL DEFAULT GETDATE(),
        modified_by                 VARCHAR(20)   NULL,
        modified_date                 DATETIME      NULL
    );
END;
GO

IF OBJECT_ID('dbo.payment_allocation_details', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.payment_allocation_details (
        payment_alloc_sno   INT IDENTITY(1,1) PRIMARY KEY,
        payment_sno           INT           NOT NULL,
        invoice_alloc_sno       INT           NOT NULL,
        amount                    DECIMAL(18,2) NOT NULL DEFAULT 0,
        created_date                DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_payment_allocation_details_payment
            FOREIGN KEY (payment_sno) REFERENCES dbo.payment_info (payment_sno),
        CONSTRAINT FK_payment_allocation_details_invoice_alloc
            FOREIGN KEY (invoice_alloc_sno) REFERENCES dbo.invoice_allocation_details (invoice_alloc_sno)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_payment_allocation_details_invoice_alloc' AND object_id = OBJECT_ID('dbo.payment_allocation_details'))
    CREATE INDEX IX_payment_allocation_details_invoice_alloc ON dbo.payment_allocation_details (invoice_alloc_sno);
GO

-- ============================================================
-- sp_nt_ReleasePayment
-- @jsonInput: { vendor_sno, payment_date, amount, mode, bank_account?,
--   reference_no?, remarks?, created_by, allocations: [{ invoice_alloc_sno, amount }] }
-- Rejects if any requested allocation amount exceeds that bucket's
-- (release_amount - already paid) — i.e. a held portion can never be paid.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_ReleasePayment', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_ReleasePayment;
GO
CREATE PROCEDURE dbo.sp_nt_ReleasePayment
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @vendor_sno     INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
        DECLARE @payment_date   DATE          = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_date') AS DATE);
        DECLARE @amount         DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.amount') AS DECIMAL(18,2));
        DECLARE @mode           VARCHAR(10)   = JSON_VALUE(@jsonInput, '$.mode');
        DECLARE @bank_account   VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.bank_account');
        DECLARE @reference_no   VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.reference_no');
        DECLARE @remarks        VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.remarks');
        DECLARE @created_by     VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
        DECLARE @allocations    NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.allocations');

        IF @vendor_sno IS NULL OR @amount IS NULL OR @mode IS NULL OR @created_by IS NULL OR @allocations IS NULL
            THROW 55001, 'vendor_sno, amount, mode, created_by and allocations are required.', 1;

        DECLARE @allocTable TABLE (invoice_alloc_sno INT, amount DECIMAL(18,2));
        INSERT INTO @allocTable (invoice_alloc_sno, amount)
        SELECT TRY_CAST(JSON_VALUE(value, '$.invoice_alloc_sno') AS INT), TRY_CAST(JSON_VALUE(value, '$.amount') AS DECIMAL(18,2))
        FROM OPENJSON(@allocations);

        IF NOT EXISTS (SELECT 1 FROM @allocTable)
            THROW 55002, 'At least one allocation is required.', 1;

        DECLARE @allocTotal DECIMAL(18,2);
        SELECT @allocTotal = SUM(amount) FROM @allocTable;
        IF ABS(ISNULL(@allocTotal, 0) - @amount) > 1.00
            THROW 55003, 'Allocation amounts must sum to the payment amount.', 1;

        -- Validate every bucket has enough un-paid release_amount left
        IF EXISTS (
            SELECT 1
            FROM @allocTable a
            JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = a.invoice_alloc_sno
            OUTER APPLY (
                SELECT paidSoFar = ISNULL(SUM(pad.amount), 0)
                FROM dbo.payment_allocation_details pad
                WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno
            ) paid
            WHERE a.amount > (iad.release_amount - paid.paidSoFar) + 0.01
        )
            THROW 55004, 'One or more allocations exceed their available (unpaid) release amount.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(payment_no, 6) AS INT)), 0) + 1
        FROM dbo.payment_info WITH (UPDLOCK, HOLDLOCK)
        WHERE payment_no LIKE 'PAY-' + @year + '-%';
        DECLARE @payment_no VARCHAR(30) = 'PAY-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

        INSERT INTO dbo.payment_info (
            payment_no, vendor_sno, payment_date, amount, mode, bank_account, reference_no,
            status, remarks, is_active, created_by, created_date
        )
        VALUES (
            @payment_no, @vendor_sno, @payment_date, @amount, @mode, @bank_account, @reference_no,
            'Processed', @remarks, 'Y', @created_by, GETDATE()
        );

        DECLARE @payment_sno INT = SCOPE_IDENTITY();

        INSERT INTO dbo.payment_allocation_details (payment_sno, invoice_alloc_sno, amount, created_date)
        SELECT @payment_sno, invoice_alloc_sno, amount, GETDATE() FROM @allocTable;

        COMMIT TRANSACTION;

        SELECT @payment_sno AS payment_sno, @payment_no AS payment_no, 'SUCCESS' AS result;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- sp_nt_GetPayableBills — matched buckets with an unpaid balance, feeds
-- Payment/PayableBillSidebar.tsx
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetPayableBills', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPayableBills;
GO
CREATE PROCEDURE dbo.sp_nt_GetPayableBills
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        iad.invoice_alloc_sno AS bill_sno,
        i.invoice_no          AS bill_no,
        i.vendor_invoice_no   AS supplier_invoice_no,
        p.po_df_no            AS po_no,
        i.vendor_sno,
        k.company_name        AS vendor_name,
        i.invoice_date,
        i.due_date,
        iad.bucket_type,
        iad.release_amount    AS net_payable,
        ISNULL(paid.paidSoFar, 0)                       AS paid_amount,
        (iad.release_amount - ISNULL(paid.paidSoFar, 0)) AS outstanding
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i        ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = i.vendor_sno
    OUTER APPLY (
        SELECT paidSoFar = ISNULL(SUM(pad.amount), 0)
        FROM dbo.payment_allocation_details pad
        WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno
    ) paid
    WHERE iad.is_active = 'Y'
      AND iad.release_amount > ISNULL(paid.paidSoFar, 0) + 0.01
    ORDER BY iad.invoice_alloc_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetPaymentHistory — feeds Payment/PaymentHistoryView.tsx
-- @jsonInput optional: { bill_sno? } (invoice_alloc_sno)
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetPaymentHistory', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPaymentHistory;
GO
CREATE PROCEDURE dbo.sp_nt_GetPaymentHistory
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @bill_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @bill_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.bill_sno') AS INT);

    SELECT
        pi.payment_sno,
        pi.payment_no,
        pad.invoice_alloc_sno AS bill_sno,
        i.invoice_no          AS bill_no,
        i.vendor_invoice_no   AS supplier_invoice_no,
        p.po_df_no            AS po_no,
        pi.vendor_sno,
        k.company_name        AS vendor_name,
        pi.payment_date,
        pad.amount,
        pi.mode,
        pi.bank_account,
        pi.reference_no,
        pi.status,
        pi.remarks,
        pi.created_by         AS created_by_name,
        pi.created_date       AS created_at
    FROM dbo.payment_allocation_details pad
    JOIN dbo.payment_info pi              ON pi.payment_sno = pad.payment_sno
    JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = pad.invoice_alloc_sno
    JOIN dbo.invoice_info i               ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.po_request_info p        ON p.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k          ON k.kyc_basic_info_sno = pi.vendor_sno
    WHERE pi.is_active = 'Y'
      AND (@bill_sno IS NULL OR pad.invoice_alloc_sno = @bill_sno)
    ORDER BY pi.payment_sno DESC;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT name FROM sys.procedures WHERE name LIKE 'sp_nt_%Payment%';
-- ============================================================
