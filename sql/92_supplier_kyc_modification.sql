-- ============================================================
-- sql/92: Supplier portal "My KYC" - a supplier sees its own KYC and changes it, with an authorization letter.
-- Database: Non_trade_Dev (MSSQL)
--
-- The /Supplier portal had no KYC screen: a supplier could not see what it had submitted, and any change (new bank
-- account, new address, new contact) had to go through the purchase team by mail. Now the supplier sees only its own KYC
-- (the portal passes the kyc_basic_info_sno from the supplier's login, never from the form) and can change it. Every change
-- needs a reason and at least one authorization letter (on letterhead, signed by an authorised signatory).
--
-- How a change is saved (sp_nt_SupplierModifyKyc, one transaction):
--   1. the WHOLE current KYC - company details, payment method, addresses, bank accounts, contacts, documents - is copied as
--      JSON into kyc_modified_data.old_data ("old data saved into modified data");
--   2. the new values are written to the live kyc_* tables:
--        company details / payment method  updated in place on kyc_basic_info;
--        addresses, bank accounts, contacts rows sent back with their sno are updated, rows without one are added,
--                                           rows left out are deactivated (is_active = 'N' - never deleted);
--        documents                          a new copy of a document replaces (deactivates) the old one of that type;
--   3. the KYC as it stands after the change goes to kyc_modified_data.new_data, with the sections that changed, the reason,
--      who did it, and the uploaded files (kyc_modified_data_file).
-- Row snos stay the same, so anything that points at a bank / address row keeps working. The Payment Run already snapshots
-- the supplier's bank account when a run is made (grn sql/68), so runs made before the change keep the old account.
--
-- What the supplier cannot change: supplier code, PAN, category, approval status, organisation.
-- When the GST number changes, the values that came from the old GSTIN lookup (gst_status, gst_blk_status, txp_type,
-- date_of_reg) are cleared - they describe the old number. They stay in old_data.
--
-- The form sends back a hash of the KYC it was opened on; if anything changed since (another tab, the purchase team), the
-- save is refused with "reload and make your change again" instead of silently overwriting.
--
-- Objects (re-runnable):
--   kyc_modified_data, kyc_modified_data_file   NEW  one row per change + the files uploaded with it
--   fn_nt_KycSnapshot(@kyc_basic_info_sno)      NEW  the KYC as one JSON document (same shape as old_data / new_data)
--   sp_nt_GetSupplierOwnKyc                     NEW  portal: my KYC, my change history, choices for the form
--   sp_nt_SupplierModifyKyc                     NEW  portal: save a change
--   sp_nt_GetSupplierFullDetails                CHANGED (backend sql/108/109) staff Supplier Status / KYC "View all":
--                                                    adds RS7 = the supplier's changes. RS1-RS6 are unchanged.
-- Errors 58601-58612 are written for the supplier and shown as they are.
-- Rollback: sql/backups/supplier_kyc_modification_2026-11-06_ROLLBACK.sql
-- ============================================================

IF OBJECT_ID('dbo.kyc_modified_data', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.kyc_modified_data (
        kyc_modified_sno   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_kyc_modified_data PRIMARY KEY,
        kyc_basic_info_sno INT            NOT NULL CONSTRAINT FK_kyc_modified_data_kyc REFERENCES dbo.kyc_basic_info (kyc_basic_info_sno),
        version_no         INT            NOT NULL,      -- 1, 2, 3 ... per supplier
        reason             NVARCHAR(500)  NOT NULL,
        changed_sections   VARCHAR(100)   NOT NULL,      -- BASIC,PAYMENT,ADDRESS,BANK,CONTACT,DOCUMENT
        old_data           NVARCHAR(MAX)  NOT NULL,      -- fn_nt_KycSnapshot before the change
        new_data           NVARCHAR(MAX)  NOT NULL,      -- fn_nt_KycSnapshot after the change
        source             VARCHAR(20)    NOT NULL CONSTRAINT DF_kyc_modified_data_source DEFAULT ('SUPPLIER_PORTAL'),
        modified_by        NVARCHAR(255)  NOT NULL,      -- the supplier's login email (or supplier code)
        modified_date      DATETIME       NOT NULL CONSTRAINT DF_kyc_modified_data_date DEFAULT (GETDATE()),
        CONSTRAINT UQ_kyc_modified_data_version UNIQUE (kyc_basic_info_sno, version_no),
        CONSTRAINT CK_kyc_modified_data_json CHECK (ISJSON(old_data) = 1 AND ISJSON(new_data) = 1)
    );
END
GO

IF OBJECT_ID('dbo.kyc_modified_data_file', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.kyc_modified_data_file (
        kyc_modified_file_sno INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_kyc_modified_data_file PRIMARY KEY,
        kyc_modified_sno      INT           NOT NULL CONSTRAINT FK_kyc_modified_data_file_head REFERENCES dbo.kyc_modified_data (kyc_modified_sno),
        file_kind             VARCHAR(30)   NOT NULL,    -- AUTHORIZATION, or the KYC document type it added (gst_file, pan_file ...)
        file_name             NVARCHAR(255) NOT NULL,
        file_path             NVARCHAR(500) NOT NULL,
        file_size             BIGINT        NULL,
        uploaded_date         DATETIME      NOT NULL CONSTRAINT DF_kyc_modified_data_file_date DEFAULT (GETDATE())
    );
    CREATE INDEX IX_kyc_modified_data_file_head ON dbo.kyc_modified_data_file (kyc_modified_sno);
END
GO

-- ------------------------------------------------------------
-- The KYC as one JSON document. Active rows only, in sno order, so two snapshots of an unchanged KYC are identical text.
-- Text is trimmed and a blank is shown as null: older rows hold '' where the change form saves NULL, and that must not
-- count as a change. Yes/No flags with no value read as 'N'.
-- Bank account numbers are text (a BIGINT does not survive JavaScript's number type).
-- ------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_nt_KycSnapshot (@kyc_basic_info_sno INT)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    RETURN (
        SELECT
            JSON_QUERY((SELECT NULLIF(TRIM(k.company_name), '') AS company_name, NULLIF(TRIM(k.legal_name), '') AS legal_name,
                               NULLIF(TRIM(k.trade_name), '') AS trade_name, NULLIF(TRIM(k.contact_person), '') AS contact_person,
                               NULLIF(TRIM(k.email), '') AS email, NULLIF(TRIM(k.mobile_number), '') AS mobile_number,
                               NULLIF(TRIM(k.business_type), '') AS business_type, bt.business_types_name AS business_type_name,
                               ISNULL(k.is_gst_avail, 'N') AS is_gst_avail, NULLIF(TRIM(k.gst_no), '') AS gst_no,
                               NULLIF(TRIM(k.gst_status), '') AS gst_status, NULLIF(TRIM(k.gst_blk_status), '') AS gst_blk_status,
                               NULLIF(TRIM(k.txp_type), '') AS txp_type, k.date_of_reg,
                               ISNULL(k.is_msme_avail, 'N') AS is_msme_avail, NULLIF(TRIM(k.msme_no), '') AS msme_no,
                               NULLIF(TRIM(k.msme_type), '') AS msme_type, NULLIF(TRIM(k.pan_no), '') AS pan_no
                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)) AS basic,
            JSON_QUERY((SELECT ISNULL(k.pay_via_portal, 'N') AS pay_via_portal,
                               NULLIF(TRIM(k.payment_portal_name), '') AS payment_portal_name,
                               NULLIF(TRIM(k.payment_portal_url), '') AS payment_portal_url,
                               NULLIF(TRIM(k.payment_instructions), '') AS payment_instructions
                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)) AS payment,
            JSON_QUERY(ISNULL((SELECT a.kyc_address_sno, NULLIF(TRIM(a.address_type), '') AS address_type,
                                      NULLIF(TRIM(a.door_no), '') AS door_no, NULLIF(TRIM(a.street), '') AS street,
                                      NULLIF(TRIM(a.area), '') AS area, NULLIF(TRIM(a.city), '') AS city,
                                      NULLIF(TRIM(a.taluk), '') AS taluk, NULLIF(TRIM(a.state), '') AS state, a.state_code,
                                      NULLIF(TRIM(a.pincode), '') AS pincode, NULLIF(TRIM(a.location_link), '') AS location_link,
                                      ISNULL(a.is_primary, 'N') AS is_primary
                               FROM dbo.kyc_address_info a
                               WHERE a.kyc_basic_info_sno = k.kyc_basic_info_sno AND ISNULL(a.is_active, 'Y') <> 'N'
                               ORDER BY a.kyc_address_sno
                               FOR JSON PATH, INCLUDE_NULL_VALUES), N'[]')) AS addresses,
            JSON_QUERY(ISNULL((SELECT b.kyc_address_sno AS kyc_bank_sno, NULLIF(TRIM(b.ac_holder_name), '') AS ac_holder_name,
                                      CAST(b.ac_number AS VARCHAR(30)) AS ac_number, NULLIF(TRIM(b.ac_type), '') AS ac_type,
                                      bat.account_type_name AS ac_type_name, NULLIF(TRIM(b.ifsc), '') AS ifsc,
                                      NULLIF(TRIM(b.bank_name), '') AS bank_name, NULLIF(TRIM(b.bank_branch_name), '') AS bank_branch_name,
                                      NULLIF(TRIM(b.bank_address), '') AS bank_address, ISNULL(b.is_primary, 'N') AS is_primary
                               FROM dbo.kyc_bank_info b
                               LEFT JOIN dbo.bank_account_type_master bat ON bat.bank_account_type_sno = TRY_CONVERT(INT, b.ac_type)
                               WHERE b.kyc_basic_info_sno = k.kyc_basic_info_sno AND ISNULL(b.is_active, 'Y') <> 'N'
                               ORDER BY b.kyc_address_sno
                               FOR JSON PATH, INCLUDE_NULL_VALUES), N'[]')) AS banks,
            JSON_QUERY(ISNULL((SELECT c.kyc_contact_sno, NULLIF(TRIM(c.contact_type), '') AS contact_type,
                                      NULLIF(TRIM(c.contact_name), '') AS contact_name,
                                      NULLIF(TRIM(c.contact_position), '') AS contact_position,
                                      NULLIF(TRIM(c.contact_mobile), '') AS contact_mobile,
                                      NULLIF(TRIM(c.contact_email), '') AS contact_email
                               FROM dbo.kyc_contact_info c
                               WHERE c.kyc_basic_info_sno = k.kyc_basic_info_sno AND ISNULL(c.is_active, 'Y') <> 'N'
                               ORDER BY c.kyc_contact_sno
                               FOR JSON PATH, INCLUDE_NULL_VALUES), N'[]')) AS contacts,
            JSON_QUERY(ISNULL((SELECT d.kyc_document_sno, d.document_type, d.document_name, d.document_path, d.uploaded_date
                               FROM dbo.kyc_document_info d
                               WHERE d.kyc_basic_info_sno = k.kyc_basic_info_sno AND ISNULL(d.is_active, 'Y') <> 'N'
                               ORDER BY d.kyc_document_sno
                               FOR JSON PATH, INCLUDE_NULL_VALUES), N'[]')) AS documents
        FROM dbo.kyc_basic_info k
        LEFT JOIN dbo.business_types bt ON bt.business_types_id = TRY_CONVERT(INT, k.business_type)
        WHERE k.kyc_basic_info_sno = @kyc_basic_info_sno
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
    );
END
GO

-- ------------------------------------------------------------
-- Portal: the logged-in supplier's own KYC.
--   RS1 what only the purchase team can change + the KYC snapshot + the hash the change form sends back
--   RS2 the supplier's changes, newest first (old / new snapshots + files)
--   RS3 business types, RS4 bank account types (choices for the form)
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetSupplierOwnKyc
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @k INT = TRY_CONVERT(INT, JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno'));

    IF NOT EXISTS (SELECT 1 FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = @k AND ISNULL(is_active, 'Y') <> 'N')
        THROW 58601, N'Your KYC record was not found. Please contact the purchase team.', 1;

    DECLARE @snapshot NVARCHAR(MAX) = dbo.fn_nt_KycSnapshot(@k);

    SELECT k.kyc_basic_info_sno, k.supp_code, k.status, k.pan_no,
           COALESCE(sc.supp_cat_name, k.supplier_cat_code) AS supplier_category,
           CASE WHEN k.vendor_category = 'SERVICE' THEN 'Service Vendor' ELSE 'Supplier' END AS category,
           k.created_date, k.modified_date,
           @snapshot AS snapshot,
           CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', @snapshot), 2) AS snapshot_hash
    FROM dbo.kyc_basic_info k
    OUTER APPLY (SELECT TOP 1 s.supp_cat_name FROM dbo.supplier_category s
                 WHERE s.supp_cat_code = k.supplier_cat_code ORDER BY s.supp_cat_sno) sc
    WHERE k.kyc_basic_info_sno = @k;

    SELECT m.kyc_modified_sno, m.version_no, m.reason, m.changed_sections, m.old_data, m.new_data,
           m.source, m.modified_by, m.modified_date,
           (SELECT f.file_kind, f.file_name, f.file_path, f.file_size, f.uploaded_date
            FROM dbo.kyc_modified_data_file f
            WHERE f.kyc_modified_sno = m.kyc_modified_sno
            ORDER BY f.kyc_modified_file_sno
            FOR JSON PATH) AS files
    FROM dbo.kyc_modified_data m
    WHERE m.kyc_basic_info_sno = @k
    ORDER BY m.version_no DESC;

    SELECT CAST(business_types_id AS VARCHAR(20)) AS value, business_types_name AS label
    FROM dbo.business_types
    WHERE IsActive = 1
    ORDER BY business_types_id;

    SELECT CAST(bank_account_type_sno AS VARCHAR(20)) AS value, account_type_name AS label
    FROM dbo.bank_account_type_master
    WHERE is_active = 'Y'
    ORDER BY bank_account_type_sno;
END
GO

-- ------------------------------------------------------------
-- Portal: save a change to the supplier's own KYC (see the header for what happens).
-- @jsonInput: {
--   kyc_basic_info_sno, snapshot_hash, reason, modified_by, modified_by_code,
--   basic:     { company_name, legal_name, trade_name, contact_person, email, mobile_number, business_type,
--                is_gst_avail, gst_no, is_msme_avail, msme_no, msme_type,
--                pay_via_portal, payment_portal_name, payment_portal_url, payment_instructions },
--   addresses: [{ kyc_address_sno?, door_no, street, area, city, taluk, state, state_code, pincode, location_link, is_primary }],
--   banks:     [{ kyc_bank_sno?, ac_holder_name, ac_number, ac_type, ifsc, bank_name, bank_branch_name, bank_address, is_primary }],
--   contacts:  [{ kyc_contact_sno?, contact_name, contact_position, contact_mobile, contact_email, is_primary }],
--   documents: [{ document_type, document_name, document_path, file_size }]     new KYC documents (optional)
--   files:     [{ file_kind, file_name, file_path, file_size }]                  everything uploaded with this change;
--                                                                               at least one file_kind = 'AUTHORIZATION'
-- }
-- The service (grn-service supplier.service.js) checks formats and lengths with friendly messages first; this procedure
-- re-checks the rules that keep the data whole, and that every row the form names is this supplier's own.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_nt_SupplierModifyKyc
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @k       INT           = TRY_CONVERT(INT, JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno'));
    DECLARE @hash    VARCHAR(64)   = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.snapshot_hash'))), '');
    DECLARE @reason  NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.reason'))), '');
    DECLARE @by      NVARCHAR(255) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.modified_by'))), '');
    DECLARE @by_code VARCHAR(20)   = LEFT(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.modified_by_code'))), ''), 20);
    DECLARE @basic   NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.basic');

    DECLARE @company_name NVARCHAR(50), @legal_name VARCHAR(100), @trade_name VARCHAR(100), @contact_person NVARCHAR(50),
            @email NVARCHAR(50), @mobile VARCHAR(15), @business_type NVARCHAR(50),
            @is_gst CHAR(1), @gst_no VARCHAR(20), @is_msme CHAR(1), @msme_no VARCHAR(20), @msme_type VARCHAR(20),
            @portal CHAR(1), @portal_name NVARCHAR(150), @portal_url NVARCHAR(500), @portal_instr NVARCHAR(1000);

    SELECT @company_name   = NULLIF(LTRIM(RTRIM(j.company_name)), ''),
           @legal_name     = NULLIF(LTRIM(RTRIM(j.legal_name)), ''),
           @trade_name     = NULLIF(LTRIM(RTRIM(j.trade_name)), ''),
           @contact_person = NULLIF(LTRIM(RTRIM(j.contact_person)), ''),
           @email          = NULLIF(LTRIM(RTRIM(j.email)), ''),
           @mobile         = NULLIF(LTRIM(RTRIM(j.mobile_number)), ''),
           @business_type  = NULLIF(LTRIM(RTRIM(j.business_type)), ''),
           @is_gst         = CASE WHEN j.is_gst_avail = 'Y' THEN 'Y' ELSE 'N' END,
           @gst_no         = UPPER(NULLIF(LTRIM(RTRIM(j.gst_no)), '')),
           @is_msme        = CASE WHEN j.is_msme_avail = 'Y' THEN 'Y' ELSE 'N' END,
           @msme_no        = UPPER(NULLIF(LTRIM(RTRIM(j.msme_no)), '')),
           @msme_type      = NULLIF(LTRIM(RTRIM(j.msme_type)), ''),
           @portal         = CASE WHEN j.pay_via_portal = 'Y' THEN 'Y' ELSE 'N' END,
           @portal_name    = NULLIF(LTRIM(RTRIM(j.payment_portal_name)), ''),
           @portal_url     = NULLIF(LTRIM(RTRIM(j.payment_portal_url)), ''),
           @portal_instr   = NULLIF(LTRIM(RTRIM(j.payment_instructions)), '')
    FROM OPENJSON(@basic) WITH (
        company_name NVARCHAR(50), legal_name VARCHAR(100), trade_name VARCHAR(100), contact_person NVARCHAR(50),
        email NVARCHAR(50), mobile_number VARCHAR(15), business_type NVARCHAR(50),
        is_gst_avail VARCHAR(1), gst_no VARCHAR(20), is_msme_avail VARCHAR(1), msme_no VARCHAR(20), msme_type VARCHAR(20),
        pay_via_portal VARCHAR(1), payment_portal_name NVARCHAR(150), payment_portal_url NVARCHAR(500),
        payment_instructions NVARCHAR(1000)
    ) j;

    IF @is_gst = 'N' SET @gst_no = NULL;
    IF @is_msme = 'N' SELECT @msme_no = NULL, @msme_type = NULL;
    IF @portal = 'N' SELECT @portal_name = NULL, @portal_url = NULL, @portal_instr = NULL;

    -- ---- the form, one row per entry
    DECLARE @addr TABLE (row_no INT NOT NULL, kyc_address_sno INT NULL, door_no NVARCHAR(300), street NVARCHAR(200),
                         area NVARCHAR(200), city NVARCHAR(200), taluk NVARCHAR(200), state NVARCHAR(200), state_code INT,
                         pincode VARCHAR(10), location_link NVARCHAR(500), is_primary CHAR(1) NOT NULL);
    INSERT @addr
    SELECT CAST(r.[key] AS INT), j.kyc_address_sno,
           NULLIF(LTRIM(RTRIM(j.door_no)), ''), NULLIF(LTRIM(RTRIM(j.street)), ''), NULLIF(LTRIM(RTRIM(j.area)), ''),
           NULLIF(LTRIM(RTRIM(j.city)), ''), NULLIF(LTRIM(RTRIM(j.taluk)), ''), NULLIF(LTRIM(RTRIM(j.state)), ''),
           TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(j.state_code)), '')), NULLIF(LTRIM(RTRIM(j.pincode)), ''),
           NULLIF(LTRIM(RTRIM(j.location_link)), ''), CASE WHEN j.is_primary = 'Y' THEN 'Y' ELSE 'N' END
    FROM OPENJSON(@jsonInput, '$.addresses') r
    CROSS APPLY OPENJSON(r.value) WITH (
        kyc_address_sno INT, door_no NVARCHAR(300), street NVARCHAR(200), area NVARCHAR(200), city NVARCHAR(200),
        taluk NVARCHAR(200), state NVARCHAR(200), state_code NVARCHAR(10), pincode VARCHAR(10), location_link NVARCHAR(500),
        is_primary VARCHAR(1)
    ) j;

    DECLARE @bank TABLE (row_no INT NOT NULL, kyc_bank_sno INT NULL, ac_holder_name NVARCHAR(50), ac_number BIGINT,
                         ac_type NVARCHAR(50), ifsc NVARCHAR(50), bank_name NVARCHAR(50), bank_branch_name NVARCHAR(50),
                         bank_address VARCHAR(300), is_primary CHAR(1) NOT NULL);
    IF @portal = 'N'
        INSERT @bank
        SELECT CAST(r.[key] AS INT), j.kyc_bank_sno,
               NULLIF(LTRIM(RTRIM(j.ac_holder_name)), ''), TRY_CONVERT(BIGINT, NULLIF(LTRIM(RTRIM(j.ac_number)), '')),
               NULLIF(LTRIM(RTRIM(j.ac_type)), ''), UPPER(NULLIF(LTRIM(RTRIM(j.ifsc)), '')),
               NULLIF(LTRIM(RTRIM(j.bank_name)), ''), NULLIF(LTRIM(RTRIM(j.bank_branch_name)), ''),
               NULLIF(LTRIM(RTRIM(j.bank_address)), ''), CASE WHEN j.is_primary = 'Y' THEN 'Y' ELSE 'N' END
        FROM OPENJSON(@jsonInput, '$.banks') r
        CROSS APPLY OPENJSON(r.value) WITH (
            kyc_bank_sno INT, ac_holder_name NVARCHAR(50), ac_number NVARCHAR(40), ac_type NVARCHAR(50), ifsc NVARCHAR(50),
            bank_name NVARCHAR(50), bank_branch_name NVARCHAR(50), bank_address VARCHAR(300), is_primary VARCHAR(1)
        ) j;

    DECLARE @cont TABLE (row_no INT NOT NULL, kyc_contact_sno INT NULL, contact_name VARCHAR(50), contact_position VARCHAR(50),
                         contact_mobile VARCHAR(15), contact_email VARCHAR(50), is_primary CHAR(1) NOT NULL);
    INSERT @cont
    SELECT CAST(r.[key] AS INT), j.kyc_contact_sno,
           NULLIF(LTRIM(RTRIM(j.contact_name)), ''), NULLIF(LTRIM(RTRIM(j.contact_position)), ''),
           NULLIF(LTRIM(RTRIM(j.contact_mobile)), ''), NULLIF(LTRIM(RTRIM(j.contact_email)), ''),
           CASE WHEN j.is_primary = 'Y' THEN 'Y' ELSE 'N' END
    FROM OPENJSON(@jsonInput, '$.contacts') r
    CROSS APPLY OPENJSON(r.value) WITH (
        kyc_contact_sno INT, contact_name VARCHAR(50), contact_position VARCHAR(50), contact_mobile VARCHAR(15),
        contact_email VARCHAR(50), is_primary VARCHAR(1)
    ) j;

    DECLARE @docs TABLE (document_type VARCHAR(20), document_name NVARCHAR(255), document_path NVARCHAR(500), file_size BIGINT);
    INSERT @docs
    SELECT NULLIF(LTRIM(RTRIM(j.document_type)), ''), ISNULL(NULLIF(LTRIM(RTRIM(j.document_name)), ''), N'Document'),
           NULLIF(LTRIM(RTRIM(j.document_path)), ''), j.file_size
    FROM OPENJSON(@jsonInput, '$.documents') WITH (
        document_type VARCHAR(20), document_name NVARCHAR(255), document_path NVARCHAR(500), file_size BIGINT
    ) j;

    DECLARE @files TABLE (file_kind VARCHAR(30), file_name NVARCHAR(255), file_path NVARCHAR(500), file_size BIGINT);
    INSERT @files
    SELECT NULLIF(LTRIM(RTRIM(j.file_kind)), ''), ISNULL(NULLIF(LTRIM(RTRIM(j.file_name)), ''), N'File'),
           NULLIF(LTRIM(RTRIM(j.file_path)), ''), j.file_size
    FROM OPENJSON(@jsonInput, '$.files') WITH (
        file_kind VARCHAR(30), file_name NVARCHAR(255), file_path NVARCHAR(500), file_size BIGINT
    ) j;

    -- ---- rules that keep the KYC whole
    IF @k IS NULL
        THROW 58601, N'Your KYC record was not found. Please contact the purchase team.', 1;
    IF @reason IS NULL
        THROW 58602, N'Tell us why these details are changing.', 1;
    IF @by IS NULL
        THROW 58603, N'The login making this change is missing.', 1;
    IF @basic IS NULL OR @company_name IS NULL OR @contact_person IS NULL OR @email IS NULL OR @mobile IS NULL OR @business_type IS NULL
        THROW 58604, N'Company name, contact person, mobile, email and business type are required.', 1;
    IF @is_gst = 'Y' AND @gst_no IS NULL
        THROW 58604, N'Enter your GST number, or choose that you are not GST registered.', 1;
    IF @is_msme = 'Y' AND @msme_no IS NULL
        THROW 58604, N'Enter your MSME (Udyam) number, or choose that you are not MSME registered.', 1;
    IF @portal = 'Y' AND (@portal_name IS NULL OR @portal_url IS NULL)
        THROW 58604, N'Enter the name and web address of the portal you are paid through.', 1;
    IF NOT EXISTS (SELECT 1 FROM @files WHERE file_kind = 'AUTHORIZATION' AND file_path IS NOT NULL)
        THROW 58605, N'Upload the authorization letter for this change.', 1;
    IF (SELECT COUNT(*) FROM @addr WHERE is_primary = 'Y') <> 1
        THROW 58606, N'Keep exactly one primary address.', 1;
    IF EXISTS (SELECT 1 FROM @addr WHERE door_no IS NULL OR street IS NULL OR area IS NULL OR city IS NULL OR state IS NULL OR pincode IS NULL)
        THROW 58606, N'Every address needs the door / building, street, area, city, state and pincode.', 1;
    IF @portal = 'N' AND (SELECT COUNT(*) FROM @bank WHERE is_primary = 'Y') <> 1
        THROW 58607, N'Keep exactly one primary bank account, or choose to be paid through your portal.', 1;
    IF EXISTS (SELECT 1 FROM @bank WHERE ac_holder_name IS NULL OR ac_number IS NULL OR ac_type IS NULL OR ifsc IS NULL
                                       OR bank_name IS NULL OR bank_branch_name IS NULL)
        THROW 58607, N'Every bank account needs the holder name, account number, account type, IFSC, bank and branch.', 1;
    IF (SELECT COUNT(*) FROM @cont WHERE is_primary = 'Y') <> 1
        THROW 58608, N'Keep exactly one primary contact.', 1;
    IF EXISTS (SELECT 1 FROM @cont WHERE contact_name IS NULL OR contact_mobile IS NULL OR contact_email IS NULL)
        THROW 58608, N'Every contact needs a name, mobile and email.', 1;
    IF EXISTS (SELECT 1 FROM @docs WHERE document_path IS NULL
                  OR document_type NOT IN ('pan_file', 'gst_file', 'msme_file', 'bankCancelCheque_0', 'other_file'))
        THROW 58610, N'One of the new documents has no file or an unknown document type.', 1;

    BEGIN TRY
        BEGIN TRAN;

        -- one change at a time per supplier; the hash proves the form was opened on the KYC as it is now
        DECLARE @old_gst VARCHAR(20);
        SELECT @old_gst = gst_no
        FROM dbo.kyc_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE kyc_basic_info_sno = @k AND ISNULL(is_active, 'Y') <> 'N';
        IF @@ROWCOUNT = 0
            THROW 58601, N'Your KYC record was not found. Please contact the purchase team.', 1;

        DECLARE @old NVARCHAR(MAX) = dbo.fn_nt_KycSnapshot(@k);
        IF @hash IS NULL OR @hash <> CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', @old), 2)
            THROW 58611, N'Your KYC was changed after you opened this form. Reload the page and make your change again.', 1;

        -- every row the form names must be one of this supplier's active rows, named once
        IF EXISTS (SELECT kyc_address_sno FROM @addr WHERE kyc_address_sno IS NOT NULL GROUP BY kyc_address_sno HAVING COUNT(*) > 1)
           OR EXISTS (SELECT kyc_bank_sno FROM @bank WHERE kyc_bank_sno IS NOT NULL GROUP BY kyc_bank_sno HAVING COUNT(*) > 1)
           OR EXISTS (SELECT kyc_contact_sno FROM @cont WHERE kyc_contact_sno IS NOT NULL GROUP BY kyc_contact_sno HAVING COUNT(*) > 1)
           OR EXISTS (SELECT 1 FROM @addr n WHERE n.kyc_address_sno IS NOT NULL AND NOT EXISTS (
                          SELECT 1 FROM dbo.kyc_address_info a
                          WHERE a.kyc_address_sno = n.kyc_address_sno AND a.kyc_basic_info_sno = @k AND ISNULL(a.is_active, 'Y') <> 'N'))
           OR EXISTS (SELECT 1 FROM @bank n WHERE n.kyc_bank_sno IS NOT NULL AND NOT EXISTS (
                          SELECT 1 FROM dbo.kyc_bank_info b
                          WHERE b.kyc_address_sno = n.kyc_bank_sno AND b.kyc_basic_info_sno = @k AND ISNULL(b.is_active, 'Y') <> 'N'))
           OR EXISTS (SELECT 1 FROM @cont n WHERE n.kyc_contact_sno IS NOT NULL AND NOT EXISTS (
                          SELECT 1 FROM dbo.kyc_contact_info c
                          WHERE c.kyc_contact_sno = n.kyc_contact_sno AND c.kyc_basic_info_sno = @k AND ISNULL(c.is_active, 'Y') <> 'N'))
            THROW 58609, N'This form no longer matches your KYC. Reload the page and make your change again.', 1;

        -- ---- company details + payment method
        DECLARE @gst_changed BIT = CASE WHEN ISNULL(UPPER(@old_gst), '') <> ISNULL(@gst_no, '') THEN 1 ELSE 0 END;

        UPDATE dbo.kyc_basic_info
        SET company_name         = @company_name,
            legal_name           = @legal_name,
            trade_name           = @trade_name,
            contact_person       = @contact_person,
            email                = @email,
            mobile_number        = @mobile,
            business_type        = @business_type,
            is_gst_avail         = @is_gst,
            gst_no               = @gst_no,
            gst_status           = CASE WHEN @gst_changed = 1 THEN NULL ELSE gst_status END,
            gst_blk_status       = CASE WHEN @gst_changed = 1 THEN NULL ELSE gst_blk_status END,
            txp_type             = CASE WHEN @gst_changed = 1 THEN NULL ELSE txp_type END,
            date_of_reg          = CASE WHEN @gst_changed = 1 THEN NULL ELSE date_of_reg END,
            is_msme_avail        = @is_msme,
            msme_no              = @msme_no,
            msme_type            = @msme_type,
            pay_via_portal       = @portal,
            payment_portal_name  = @portal_name,
            payment_portal_url   = @portal_url,
            payment_instructions = @portal_instr,
            modified_by          = ISNULL(@by_code, LEFT(@by, 20)),
            modified_date        = GETDATE()
        WHERE kyc_basic_info_sno = @k;

        -- ---- addresses: update the ones sent back, deactivate the ones left out, add the new ones
        UPDATE a
        SET door_no = n.door_no, street = n.street, area = n.area, city = n.city, taluk = n.taluk, state = n.state,
            state_code = n.state_code, pincode = n.pincode, location_link = n.location_link, is_primary = n.is_primary,
            address_type = CASE WHEN n.is_primary = 'Y' THEN 'PRIMARY'
                                WHEN a.address_type IS NULL OR a.address_type = 'PRIMARY' THEN 'SECONDARY'
                                ELSE a.address_type END
        FROM dbo.kyc_address_info a
        JOIN @addr n ON n.kyc_address_sno = a.kyc_address_sno
        WHERE a.kyc_basic_info_sno = @k;

        UPDATE dbo.kyc_address_info
        SET is_active = 'N'
        WHERE kyc_basic_info_sno = @k AND ISNULL(is_active, 'Y') <> 'N'
          AND kyc_address_sno NOT IN (SELECT kyc_address_sno FROM @addr WHERE kyc_address_sno IS NOT NULL);

        INSERT dbo.kyc_address_info (kyc_basic_info_sno, address_type, door_no, street, area, city, taluk, state, state_code,
                                     pincode, location_link, is_primary)
        SELECT @k, CASE WHEN is_primary = 'Y' THEN 'PRIMARY' ELSE 'SECONDARY' END, door_no, street, area, city, taluk, state,
               state_code, pincode, location_link, is_primary
        FROM @addr
        WHERE kyc_address_sno IS NULL
        ORDER BY row_no;

        -- ---- bank accounts (all deactivated when the supplier is now paid through its portal - @bank is empty then)
        UPDATE b
        SET ac_holder_name = n.ac_holder_name, ac_number = n.ac_number, ac_type = n.ac_type, ifsc = n.ifsc,
            bank_name = n.bank_name, bank_branch_name = n.bank_branch_name, bank_address = n.bank_address,
            is_primary = n.is_primary
        FROM dbo.kyc_bank_info b
        JOIN @bank n ON n.kyc_bank_sno = b.kyc_address_sno
        WHERE b.kyc_basic_info_sno = @k;

        UPDATE dbo.kyc_bank_info
        SET is_active = 'N'
        WHERE kyc_basic_info_sno = @k AND ISNULL(is_active, 'Y') <> 'N'
          AND kyc_address_sno NOT IN (SELECT kyc_bank_sno FROM @bank WHERE kyc_bank_sno IS NOT NULL);

        INSERT dbo.kyc_bank_info (kyc_basic_info_sno, ac_holder_name, ac_number, ac_type, ifsc, bank_name, bank_branch_name,
                                  bank_address, is_primary)
        SELECT @k, ac_holder_name, ac_number, ac_type, ifsc, bank_name, bank_branch_name, bank_address, is_primary
        FROM @bank
        WHERE kyc_bank_sno IS NULL
        ORDER BY row_no;

        -- ---- contacts
        UPDATE c
        SET contact_name = n.contact_name, contact_position = n.contact_position, contact_mobile = n.contact_mobile,
            contact_email = n.contact_email,
            contact_type = CASE WHEN n.is_primary = 'Y' THEN 'PRIMARY'
                                WHEN c.contact_type IS NULL OR c.contact_type = 'PRIMARY' THEN 'SECONDARY'
                                ELSE c.contact_type END
        FROM dbo.kyc_contact_info c
        JOIN @cont n ON n.kyc_contact_sno = c.kyc_contact_sno
        WHERE c.kyc_basic_info_sno = @k;

        UPDATE dbo.kyc_contact_info
        SET is_active = 'N'
        WHERE kyc_basic_info_sno = @k AND ISNULL(is_active, 'Y') <> 'N'
          AND kyc_contact_sno NOT IN (SELECT kyc_contact_sno FROM @cont WHERE kyc_contact_sno IS NOT NULL);

        INSERT dbo.kyc_contact_info (kyc_basic_info_sno, contact_type, contact_name, contact_position, contact_mobile, contact_email)
        SELECT @k, CASE WHEN is_primary = 'Y' THEN 'PRIMARY' ELSE 'SECONDARY' END, contact_name, contact_position,
               contact_mobile, contact_email
        FROM @cont
        WHERE kyc_contact_sno IS NULL
        ORDER BY row_no;

        -- ---- documents: a new copy replaces the old one of the same type ("other_file" only adds)
        UPDATE dbo.kyc_document_info
        SET is_active = 'N'
        WHERE kyc_basic_info_sno = @k AND ISNULL(is_active, 'Y') <> 'N'
          AND document_type IN (SELECT document_type FROM @docs WHERE document_type <> 'other_file');

        INSERT dbo.kyc_document_info (kyc_basic_info_sno, document_type, document_name, document_path, file_size)
        SELECT @k, document_type, document_name, document_path, file_size
        FROM @docs;

        -- ---- what changed (binary compare: "mumbai" -> "Mumbai" is a change)
        DECLARE @new NVARCHAR(MAX) = dbo.fn_nt_KycSnapshot(@k);
        DECLARE @sections VARCHAR(100) = CONCAT_WS(',',
            CASE WHEN ISNULL(JSON_QUERY(@old, '$.basic'), N'')     COLLATE Latin1_General_BIN2 <> ISNULL(JSON_QUERY(@new, '$.basic'), N'')     COLLATE Latin1_General_BIN2 THEN 'BASIC' END,
            CASE WHEN ISNULL(JSON_QUERY(@old, '$.payment'), N'')   COLLATE Latin1_General_BIN2 <> ISNULL(JSON_QUERY(@new, '$.payment'), N'')   COLLATE Latin1_General_BIN2 THEN 'PAYMENT' END,
            CASE WHEN ISNULL(JSON_QUERY(@old, '$.addresses'), N'') COLLATE Latin1_General_BIN2 <> ISNULL(JSON_QUERY(@new, '$.addresses'), N'') COLLATE Latin1_General_BIN2 THEN 'ADDRESS' END,
            CASE WHEN ISNULL(JSON_QUERY(@old, '$.banks'), N'')     COLLATE Latin1_General_BIN2 <> ISNULL(JSON_QUERY(@new, '$.banks'), N'')     COLLATE Latin1_General_BIN2 THEN 'BANK' END,
            CASE WHEN ISNULL(JSON_QUERY(@old, '$.contacts'), N'')  COLLATE Latin1_General_BIN2 <> ISNULL(JSON_QUERY(@new, '$.contacts'), N'')  COLLATE Latin1_General_BIN2 THEN 'CONTACT' END,
            CASE WHEN ISNULL(JSON_QUERY(@old, '$.documents'), N'') COLLATE Latin1_General_BIN2 <> ISNULL(JSON_QUERY(@new, '$.documents'), N'') COLLATE Latin1_General_BIN2 THEN 'DOCUMENT' END);

        IF @sections = ''
            THROW 58612, N'Nothing has changed. Edit a detail or upload a new document before you submit.', 1;

        DECLARE @version INT = 1 + ISNULL((SELECT MAX(version_no) FROM dbo.kyc_modified_data WHERE kyc_basic_info_sno = @k), 0);

        INSERT dbo.kyc_modified_data (kyc_basic_info_sno, version_no, reason, changed_sections, old_data, new_data, modified_by)
        VALUES (@k, @version, @reason, @sections, @old, @new, @by);

        DECLARE @msno INT = SCOPE_IDENTITY();

        INSERT dbo.kyc_modified_data_file (kyc_modified_sno, file_kind, file_name, file_path, file_size)
        SELECT @msno, ISNULL(file_kind, 'OTHER'), file_name, file_path, file_size
        FROM @files
        WHERE file_path IS NOT NULL;

        COMMIT;

        SELECT @msno AS kyc_modified_sno, @version AS version_no, @sections AS changed_sections,
               k.company_name, k.supp_code, k.email, k.approver_ecno, k.created_by
        FROM dbo.kyc_basic_info k
        WHERE k.kyc_basic_info_sno = @k;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

-- ------------------------------------------------------------
-- Staff: Supplier Status / KYC "View all" (backend-stpl sql/108, portal columns from sql/109).
-- RS1-RS6 exactly as before; RS7 = the changes the supplier made on the portal, newest first.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetSupplierFullDetails
    @source    VARCHAR(12),
    @record_id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 'KYC' AS source, k.kyc_basic_info_sno AS record_id,
           COALESCE(NULLIF(LTRIM(RTRIM(k.company_name)), ''), k.legal_name, k.trade_name) AS company_name,
           k.legal_name, k.trade_name, k.supp_code, k.status,
           CASE WHEN k.vendor_category = 'SERVICE' THEN 'Service Vendor' ELSE 'Supplier' END AS category,
           k.contact_person, k.email, k.mobile_number,
           COALESCE(bt.business_types_name, NULLIF(LTRIM(RTRIM(k.business_type)), '')) AS business_type_name,
           k.is_gst_avail, k.gst_no, k.gst_status, k.gst_blk_status, k.date_of_reg,
           k.is_msme_avail, k.msme_no, k.pan_no, k.created_by, k.created_date,
           k.pay_via_portal, k.payment_portal_name, k.payment_portal_url, k.payment_instructions
    FROM dbo.kyc_basic_info k
    LEFT JOIN dbo.business_types bt ON bt.business_types_id = TRY_CONVERT(INT, k.business_type)
    WHERE k.kyc_basic_info_sno = @record_id;

    SELECT a.address_type, a.door_no, a.street, a.area, a.city, a.taluk, a.state, a.state_code,
           a.pincode, a.location_link, a.is_primary
    FROM dbo.kyc_address_info a
    WHERE a.kyc_basic_info_sno = @record_id AND ISNULL(a.is_active, 'Y') <> 'N'
    ORDER BY CASE WHEN a.address_type = 'PRIMARY' OR a.is_primary = 'Y' THEN 0 ELSE 1 END, a.kyc_address_sno;

    SELECT b.ac_holder_name, b.ac_number, b.ac_type,
           COALESCE(bat.account_type_name, NULLIF(LTRIM(RTRIM(b.ac_type)), '')) AS ac_type_name,
           b.ifsc, b.bank_name, b.bank_branch_name, b.bank_address, b.is_primary
    FROM dbo.kyc_bank_info b
    LEFT JOIN dbo.bank_account_type_master bat ON bat.bank_account_type_sno = TRY_CONVERT(INT, b.ac_type)
    WHERE b.kyc_basic_info_sno = @record_id AND ISNULL(b.is_active, 'Y') <> 'N'
    ORDER BY CASE WHEN b.is_primary = 'Y' THEN 0 ELSE 1 END, b.kyc_address_sno;

    SELECT c.contact_type, c.contact_name, c.contact_position, c.contact_mobile, c.contact_email
    FROM dbo.kyc_contact_info c
    WHERE c.kyc_basic_info_sno = @record_id AND ISNULL(c.is_active, 'Y') <> 'N'
    ORDER BY CASE WHEN c.contact_type = 'PRIMARY' THEN 0 ELSE 1 END, c.kyc_contact_sno;

    SELECT d.document_type, d.document_name, d.document_path, d.uploaded_date
    FROM dbo.kyc_document_info d
    WHERE d.kyc_basic_info_sno = @record_id AND ISNULL(d.is_active, 'Y') <> 'N'
    ORDER BY d.kyc_document_sno;

    SELECT r.verify_type, r.identifier, r.is_valid, r.pan_status, r.gst_status, r.gst_taxpayer_type,
           r.gst_last_update_date, r.nature_of_business_activities, r.msme_type, r.major_activity,
           r.udyam_registered_date, r.created_at
    FROM dbo.kyc_verification_response r
    WHERE r.kyc_basic_info_sno = @record_id
    ORDER BY r.id;

    SELECT m.kyc_modified_sno, m.version_no, m.reason, m.changed_sections, m.old_data, m.new_data,
           m.source, m.modified_by, m.modified_date,
           (SELECT f.file_kind, f.file_name, f.file_path, f.file_size, f.uploaded_date
            FROM dbo.kyc_modified_data_file f
            WHERE f.kyc_modified_sno = m.kyc_modified_sno
            ORDER BY f.kyc_modified_file_sno
            FOR JSON PATH) AS files
    FROM dbo.kyc_modified_data m
    WHERE m.kyc_basic_info_sno = @record_id
    ORDER BY m.version_no DESC;
END
GO
