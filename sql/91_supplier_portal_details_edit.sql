-- sql/91: Payment Run - the payments team can add / fix a portal supplier's portal details.
--
-- A supplier paid on its own portal (KYC pay_via_portal = 'Y', backend sql/109) keeps its portal name, address and payment
-- instructions in kyc_basic_info. Some have none (Dev: Amazon Web Service ticked "pay via portal" but left them empty), so the
-- payer had nowhere to go. "Pay on supplier portals" on Payment Run can now add or change them.
--
-- Where money goes is sensitive, so:
--   * the change goes through a payment the caller can see that is still waiting to be paid (Approved, not in a run), under the
--     caller's org scope - the same access as "Record payment" (sql/69);
--   * only portal suppliers: a bank supplier's account is never touched here (that stays in KYC);
--   * the address must be http(s) with a real host name - no spaces, no "user@" part (https://good.com@bad.com tricks);
--   * every change is logged with the old and the new values and the login that made it (kyc_portal_detail_log), and the screen
--     shows who edited them last.
--
-- Objects (re-runnable):
--   kyc_portal_detail_log                    NEW  one row per change
--   sp_nt_UpdateSupplierPortalDetails        NEW  validates, updates kyc_basic_info's 3 portal columns, logs
-- kyc_basic_info's own modified_by / modified_date are left alone (they belong to the KYC screens).
-- Error numbers 56330-56336 (56110 = no access, as in sql/69).
-- Rollback: sql/backups/supplier_portal_details_edit_2026-11-06_ROLLBACK.sql (refuses while changes are logged).

IF OBJECT_ID('dbo.kyc_portal_detail_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.kyc_portal_detail_log (
        log_sno            INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_kyc_portal_detail_log PRIMARY KEY,
        kyc_basic_info_sno INT            NOT NULL,
        payment_sno        INT            NULL,          -- the Payment Run entry it was changed from
        old_portal_name    NVARCHAR(150)  NULL,
        old_portal_url     NVARCHAR(500)  NULL,
        old_instructions   NVARCHAR(1000) NULL,
        new_portal_name    NVARCHAR(150)  NULL,
        new_portal_url     NVARCHAR(500)  NULL,
        new_instructions   NVARCHAR(1000) NULL,
        source             VARCHAR(20)    NOT NULL CONSTRAINT DF_kyc_portal_detail_log_source DEFAULT 'PAYMENT_RUN',
        changed_by         VARCHAR(30)    NOT NULL,
        changed_at         DATETIME       NOT NULL CONSTRAINT DF_kyc_portal_detail_log_at DEFAULT GETDATE()
    );
    CREATE INDEX IX_kyc_portal_detail_log_kyc ON dbo.kyc_portal_detail_log (kyc_basic_info_sno, log_sno DESC);
END
GO

-- { payment_sno, payment_portal_name, payment_portal_url, payment_instructions?, changed_by, hierarchy? }
-- An address typed without http(s):// gets https://. Returns the supplier's new portal details and who changed them.
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateSupplierPortalDetails
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ws NVARCHAR(10) = N' ' + CHAR(9) + CHAR(10) + CHAR(13);
    DECLARE @pay INT, @name NVARCHAR(MAX), @url NVARCHAR(MAX), @inst NVARCHAR(MAX), @by VARCHAR(100), @hier NVARCHAR(MAX);
    SELECT @pay  = TRY_CAST(j.payment_sno AS INT),
           @name = NULLIF(TRIM(@ws FROM j.payment_portal_name), N''),
           @url  = NULLIF(TRIM(@ws FROM j.payment_portal_url), N''),
           @inst = NULLIF(TRIM(@ws FROM j.payment_instructions), N''),
           @by   = NULLIF(TRIM(j.changed_by), ''),
           @hier = j.hierarchy
    FROM OPENJSON(@jsonInput) WITH (payment_sno NVARCHAR(20) '$.payment_sno', payment_portal_name NVARCHAR(MAX) '$.payment_portal_name',
                                    payment_portal_url NVARCHAR(MAX) '$.payment_portal_url', payment_instructions NVARCHAR(MAX) '$.payment_instructions',
                                    changed_by VARCHAR(100) '$.changed_by', hierarchy NVARCHAR(MAX) '$.hierarchy' AS JSON) j;

    IF @pay IS NULL THROW 56330, 'payment_sno is required.', 1;
    IF @by IS NULL OR LEN(@by) > 30 THROW 56330, 'The login making the change is required.', 1;
    IF @name IS NULL THROW 56331, 'Enter the portal / website name.', 1;
    IF LEN(@name) > 150 THROW 56331, 'The portal name can be at most 150 characters.', 1;
    IF @url IS NULL THROW 56332, 'Enter the portal address, e.g. https://pay.example.com', 1;
    IF @url NOT LIKE 'http://%' AND @url NOT LIKE 'https://%' AND @url NOT LIKE '%://%' SET @url = N'https://' + @url;
    IF LEN(@url) > 500 THROW 56332, 'The portal address can be at most 500 characters.', 1;
    IF @url NOT LIKE 'http://%' AND @url NOT LIKE 'https://%' THROW 56332, 'The portal address must start with http:// or https://', 1;
    IF @url LIKE N'%[' + @ws + N']%' THROW 56332, 'The portal address cannot have spaces.', 1;
    DECLARE @rest NVARCHAR(500) = SUBSTRING(@url, CHARINDEX(N'://', @url) + 3, 500);
    DECLARE @cut INT = PATINDEX(N'%[/?#]%', @rest);
    DECLARE @host NVARCHAR(500) = CASE WHEN @cut > 0 THEN LEFT(@rest, @cut - 1) ELSE @rest END;
    IF @host LIKE N'%@%' THROW 56332, 'The portal address cannot have a "name@" part - enter the site address only.', 1;
    IF CHARINDEX(N'.', @host) < 2 OR RIGHT(@host, 1) = N'.' OR @host LIKE N'%..%'
        THROW 56332, 'Enter the full portal address, e.g. https://pay.example.com', 1;
    IF LEN(@inst) > 1000 THROW 56333, 'The payment instructions can be at most 1000 characters.', 1;

    DECLARE @vendor INT, @status VARCHAR(20), @batch INT, @pn VARCHAR(30), @portal CHAR(1),
            @oname NVARCHAR(150), @ourl NVARCHAR(500), @oinst NVARCHAR(1000), @at DATETIME = GETDATE();

    BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @vendor = p.vendor_sno, @status = p.status, @batch = p.batch_sno, @pn = p.payment_no
        FROM dbo.payment_info p WHERE p.payment_sno = @pay AND p.is_active = 'Y';
        IF @status IS NULL THROW 56301, 'Payment not found.', 1;
        IF @hier IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM dbo.payment_info pi WHERE pi.payment_sno = @pay AND EXISTS (
                SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = pi.com_sno AND (h.div_sno IS NULL OR h.div_sno = pi.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = pi.brn_sno)))
            THROW 56110, 'You do not have access to this payment.', 1;
        IF @status <> 'Approved' OR @batch IS NOT NULL
            THROW 56334, 'This payment is not waiting for payment any more - its supplier''s portal details can only be changed in KYC now.', 1;

        SELECT @portal = k.pay_via_portal, @oname = k.payment_portal_name, @ourl = k.payment_portal_url, @oinst = k.payment_instructions
        FROM dbo.kyc_basic_info k WITH (UPDLOCK, HOLDLOCK) WHERE k.kyc_basic_info_sno = @vendor;
        IF ISNULL(@portal, 'N') <> 'Y' THROW 56335, 'This supplier is paid by bank transfer, not on a portal - its bank details are changed in KYC.', 1;
        IF ISNULL(@oname, N'') = @name AND ISNULL(@ourl, N'') = @url AND ISNULL(NULLIF(TRIM(@ws FROM @oinst), N''), N'') = ISNULL(@inst, N'')
            THROW 56336, 'Nothing changed.', 1;

        UPDATE dbo.kyc_basic_info
        SET payment_portal_name = @name, payment_portal_url = @url, payment_instructions = @inst
        WHERE kyc_basic_info_sno = @vendor;

        INSERT INTO dbo.kyc_portal_detail_log (kyc_basic_info_sno, payment_sno, old_portal_name, old_portal_url, old_instructions,
                                               new_portal_name, new_portal_url, new_instructions, source, changed_by, changed_at)
        VALUES (@vendor, @pay, @oname, @ourl, @oinst, @name, @url, @inst, 'PAYMENT_RUN', @by, @at);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT pi.payment_sno, pi.payment_no, @vendor AS vendor_sno, k.company_name AS vendor_name,
           k.payment_portal_name, k.payment_portal_url, k.payment_instructions,
           @by AS portal_edited_by, @at AS portal_edited_at,
           pi.com_sno, pi.div_sno, pi.brn_sno, pi.dept_sno
    FROM dbo.payment_info pi JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pi.vendor_sno
    WHERE pi.payment_sno = @pay;
END
GO
