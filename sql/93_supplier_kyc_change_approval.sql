-- ============================================================
-- sql/93: a supplier's KYC change now goes through APPROVAL STAGES before it goes live.
-- Database: Non_trade_Dev (MSSQL). Builds on sql/92 (kyc_modified_data, fn_nt_KycSnapshot).
--
-- sql/92 applied the supplier's change the moment it was submitted. Now:
--   1. SUBMIT   the change is saved as a PENDING request (status P). The live KYC does not change. The request keeps the KYC
--               as it is now (old_data), the KYC as it WOULD be (new_data - made by applying the change and rolling it back
--               to a savepoint, so it is exactly what approval will produce), the proposed values (payload) and the
--               authorization letters. Only one request can wait at a time per supplier.
--   2. APPROVE  the request follows the approval workflow's stages, one approver after another (the same workflow / stage
--               list as supplier KYC approval; the Approval Routing screen can point "KYC > Supplier KYC change" at its own
--               workflow - by default it uses the KYC one). The stages are copied onto the request when it is submitted, so
--               editing the workflow later does not change a request already in flight.
--   3. LIVE     the approver of the LAST stage approves -> the payload is applied to the live kyc_* tables (rows updated in
--               place, rows left out deactivated, a new document replaces the old of its type) and new_data is replaced by
--               the real KYC after the change. Old data stays in kyc_modified_data as before. If the live KYC was changed by
--               someone else after the request was made, the final approval is refused (58621): reject it and the supplier
--               sends it again, so an old form can never overwrite newer data.
--   4. REJECT   any approver can reject (a reason is required); the KYC stays as it was and the supplier sees the reason.
--               The supplier can also withdraw a request that is still waiting.
--
-- Objects (re-runnable):
--   kyc_modified_data            CHANGED  + status (P pending, A applied, R rejected, C withdrawn), payload, stages_json,
--                                          workflow_types_id, current_seq, current_approver_ecno, base_hash, decided_by,
--                                          decided_date, decision_note; one pending request per supplier (unique index)
--   kyc_modified_approval        NEW      one row per approve / reject action (the trail)
--   sp_nt_ApplyKycChange         NEW      (internal) validates + applies a payload to the live KYC; needs an open transaction
--   sp_nt_SupplierModifyKyc      CHANGED  portal: SUBMIT a request (was: apply at once). Same input as sql/92.
--   sp_nt_WithdrawKycChange      NEW      portal: withdraw a waiting request
--   sp_nt_GetSupplierOwnKyc      CHANGED  + the waiting request and, per change, its status / stage / decision / trail
--   sp_nt_GetKycChangeApprovals  NEW      staff: requests waiting for me + the ones I decided
--   sp_nt_KycChangeAct           NEW      staff: approve / reject
--   sp_nt_GetSupplierFullDetails CHANGED  RS7 carries status, stage, decision and trail (RS1-RS6 unchanged)
--   approval_route_variant       SEED     KYC > SUPPLIER_CHANGE ("Supplier KYC change"), routed to the KYC workflow
-- No new screen: the waiting requests are listed on the EXISTING "KYC Approval Screen" (previous record vs current record, the
-- reason and the authorization letter), approved / rejected there like any KYC. Who can open that screen: sql/95.
-- Errors 58601-58630 are written for the person who sees them and shown as they are.
-- Rollback: sql/backups/supplier_kyc_change_approval_2026-11-07_ROLLBACK.sql
-- ============================================================

-- ------------------------------------------------------------
-- kyc_modified_data: approval state
-- ------------------------------------------------------------
IF COL_LENGTH('dbo.kyc_modified_data', 'status') IS NULL
    ALTER TABLE dbo.kyc_modified_data ADD
        status                CHAR(1)       NOT NULL CONSTRAINT DF_kyc_modified_data_status DEFAULT ('A'),  -- sql/92 changes were applied at once
        payload               NVARCHAR(MAX) NULL,      -- the validated change (what the portal sent), applied on the last approval
        stages_json           NVARCHAR(MAX) NULL,      -- the workflow's stages at the moment of submission
        workflow_types_id     INT           NULL,
        current_seq           INT           NULL,      -- 1-based stage the request is waiting at
        current_approver_ecno VARCHAR(30)   NULL,      -- who must act now (ecno, or login id of a non-staff approver)
        base_hash             VARCHAR(64)   NULL,      -- hash of old_data: the KYC the request was made on
        decided_by            VARCHAR(30)   NULL,      -- the login that applied / rejected / withdrew it
        decided_date          DATETIME      NULL,
        decision_note         NVARCHAR(500) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_kyc_modified_data_status')
    ALTER TABLE dbo.kyc_modified_data ADD CONSTRAINT CK_kyc_modified_data_status CHECK (status IN ('P', 'A', 'R', 'C'));
GO

-- one request waiting per supplier, enforced by the database as well as by the procedure
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_kyc_modified_data_pending' AND object_id = OBJECT_ID('dbo.kyc_modified_data'))
    CREATE UNIQUE INDEX UX_kyc_modified_data_pending ON dbo.kyc_modified_data (kyc_basic_info_sno) WHERE status = 'P';
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_kyc_modified_data_inbox' AND object_id = OBJECT_ID('dbo.kyc_modified_data'))
    CREATE INDEX IX_kyc_modified_data_inbox ON dbo.kyc_modified_data (current_approver_ecno, status);
GO

IF OBJECT_ID('dbo.kyc_modified_approval', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.kyc_modified_approval (
        kyc_modified_approval_sno INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_kyc_modified_approval PRIMARY KEY,
        kyc_modified_sno          INT           NOT NULL CONSTRAINT FK_kyc_modified_approval_head REFERENCES dbo.kyc_modified_data (kyc_modified_sno),
        seq_no                    INT           NOT NULL,      -- the stage (1-based)
        stage_name                NVARCHAR(100) NULL,
        approver_ecno             VARCHAR(30)   NOT NULL,
        action                    CHAR(1)       NOT NULL CONSTRAINT CK_kyc_modified_approval_action CHECK (action IN ('A', 'R')),
        note                      NVARCHAR(500) NULL,
        acted_date                DATETIME      NOT NULL CONSTRAINT DF_kyc_modified_approval_date DEFAULT (GETDATE())
    );
    CREATE INDEX IX_kyc_modified_approval_head ON dbo.kyc_modified_approval (kyc_modified_sno);
    CREATE INDEX IX_kyc_modified_approval_who ON dbo.kyc_modified_approval (approver_ecno);
END
GO

-- ------------------------------------------------------------
-- INTERNAL: validate a change and write it to the live KYC tables. Runs inside the caller's transaction (it is called twice:
-- on submit inside a savepoint that is rolled back - to learn what the KYC would look like - and on the last approval for real).
-- @jsonInput: { kyc_basic_info_sno, basic, addresses[], banks[], contacts[], documents[] } (see sp_nt_SupplierModifyKyc)
-- @apply_by : written to kyc_basic_info.modified_by (20 chars)
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_nt_ApplyKycChange
    @jsonInput NVARCHAR(MAX),
    @apply_by  VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    IF @@TRANCOUNT = 0
        THROW 58630, N'sp_nt_ApplyKycChange must be called inside a transaction.', 1;

    DECLARE @k     INT           = TRY_CONVERT(INT, JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno'));
    DECLARE @basic NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.basic');

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

    -- ---- rules that keep the KYC whole
    IF @k IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = @k AND ISNULL(is_active, 'Y') <> 'N')
        THROW 58601, N'Your KYC record was not found. Please contact the purchase team.', 1;
    IF @basic IS NULL OR @company_name IS NULL OR @contact_person IS NULL OR @email IS NULL OR @mobile IS NULL OR @business_type IS NULL
        THROW 58604, N'Company name, contact person, mobile, email and business type are required.', 1;
    IF @is_gst = 'Y' AND @gst_no IS NULL
        THROW 58604, N'Enter your GST number, or choose that you are not GST registered.', 1;
    IF @is_msme = 'Y' AND @msme_no IS NULL
        THROW 58604, N'Enter your MSME (Udyam) number, or choose that you are not MSME registered.', 1;
    IF @portal = 'Y' AND (@portal_name IS NULL OR @portal_url IS NULL)
        THROW 58604, N'Enter the name and web address of the portal you are paid through.', 1;
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
    DECLARE @old_gst VARCHAR(20) = (SELECT gst_no FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = @k);
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
        modified_by          = @apply_by,
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
END
GO

-- ------------------------------------------------------------
-- Portal: SUBMIT a change (was: apply it at once - sql/92).
-- @jsonInput: { kyc_basic_info_sno, snapshot_hash, reason, modified_by, modified_by_code,
--               basic{}, addresses[], banks[], contacts[], documents[], files[] }   (same shape as sql/92)
--   documents: new KYC documents (applied on approval); files: everything uploaded with the request, at least one
--   file_kind = 'AUTHORIZATION'.
-- Returns one row: the pending request and who has to act first.
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

    DECLARE @files TABLE (file_kind VARCHAR(30), file_name NVARCHAR(255), file_path NVARCHAR(500), file_size BIGINT);
    INSERT @files
    SELECT NULLIF(LTRIM(RTRIM(j.file_kind)), ''), ISNULL(NULLIF(LTRIM(RTRIM(j.file_name)), ''), N'File'),
           NULLIF(LTRIM(RTRIM(j.file_path)), ''), j.file_size
    FROM OPENJSON(@jsonInput, '$.files') WITH (
        file_kind VARCHAR(30), file_name NVARCHAR(255), file_path NVARCHAR(500), file_size BIGINT
    ) j;

    IF @k IS NULL
        THROW 58601, N'Your KYC record was not found. Please contact the purchase team.', 1;
    IF @reason IS NULL
        THROW 58602, N'Tell us why these details are changing.', 1;
    IF @by IS NULL
        THROW 58603, N'The login making this change is missing.', 1;
    IF NOT EXISTS (SELECT 1 FROM @files WHERE file_kind = 'AUTHORIZATION' AND file_path IS NOT NULL)
        THROW 58605, N'Upload the authorization letter for this change.', 1;

    BEGIN TRY
        BEGIN TRAN;

        -- one change at a time per supplier; the hash proves the form was opened on the KYC as it is now
        DECLARE @locked INT;
        SELECT @locked = kyc_basic_info_sno
        FROM dbo.kyc_basic_info WITH (UPDLOCK, HOLDLOCK)
        WHERE kyc_basic_info_sno = @k AND ISNULL(is_active, 'Y') <> 'N';
        IF @locked IS NULL
            THROW 58601, N'Your KYC record was not found. Please contact the purchase team.', 1;

        IF EXISTS (SELECT 1 FROM dbo.kyc_modified_data WHERE kyc_basic_info_sno = @k AND status = 'P')
            THROW 58614, N'You already have a change waiting for approval. Wait for the decision, or withdraw it first.', 1;

        DECLARE @old NVARCHAR(MAX) = dbo.fn_nt_KycSnapshot(@k);
        DECLARE @old_hash VARCHAR(64) = CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', @old), 2);
        IF @hash IS NULL OR @hash <> @old_hash
            THROW 58611, N'Your KYC was changed after you opened this form. Reload the page and make your change again.', 1;

        -- the approval workflow: stages are copied now so a later edit of the workflow does not change this request
        DECLARE @wf INT = dbo.fn_scopeless_workflow_types(dbo.fn_resolve_approval_entity('KYC', 'SUPPLIER_CHANGE'));
        DECLARE @stages NVARCHAR(MAX);
        IF @wf IS NOT NULL
            SELECT @stages = JSON_VALUE(s.value, '$.stage_order_json')
            FROM dbo.vw_workflow_stages ws
            CROSS APPLY OPENJSON(ws.stages_json) s
            WHERE ws.workflow_types_id = @wf AND s.[key] = '0';
        DECLARE @first VARCHAR(30), @first_name NVARCHAR(100), @total INT;
        IF @stages IS NOT NULL AND ISJSON(@stages) = 1
            SELECT @first = NULLIF(LTRIM(RTRIM(JSON_VALUE(v.value, '$.approver_ecno'))), ''),
                   @first_name = JSON_VALUE(v.value, '$.stage'),
                   @total = (SELECT COUNT(*) FROM OPENJSON(@stages))
            FROM OPENJSON(@stages) v WHERE v.[key] = '0';
        IF @first IS NULL
            THROW 58613, N'Changes to KYC details need an approval workflow with an approver, and none is set up yet. Please contact the purchase team.', 1;

        -- what the KYC WOULD be: apply the change, read it back, and undo it
        DECLARE @new NVARCHAR(MAX);
        SAVE TRANSACTION before_change;
        EXEC dbo.sp_nt_ApplyKycChange @jsonInput = @jsonInput, @apply_by = @by_code;
        SET @new = dbo.fn_nt_KycSnapshot(@k);
        ROLLBACK TRANSACTION before_change;

        -- what changed (binary compare: "mumbai" -> "Mumbai" is a change)
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

        INSERT dbo.kyc_modified_data (kyc_basic_info_sno, version_no, reason, changed_sections, old_data, new_data, modified_by,
                                      status, payload, stages_json, workflow_types_id, current_seq, current_approver_ecno, base_hash)
        VALUES (@k, @version, @reason, @sections, @old, @new, @by,
                'P', @jsonInput, @stages, @wf, 1, @first, @old_hash);

        DECLARE @msno INT = SCOPE_IDENTITY();

        INSERT dbo.kyc_modified_data_file (kyc_modified_sno, file_kind, file_name, file_path, file_size)
        SELECT @msno, ISNULL(file_kind, 'OTHER'), file_name, file_path, file_size
        FROM @files
        WHERE file_path IS NOT NULL;

        COMMIT;

        SELECT @msno AS kyc_modified_sno, @version AS version_no, @sections AS changed_sections, 'P' AS status,
               @first AS current_approver_ecno, @first_name AS stage_name, 1 AS stage_no, @total AS stage_total,
               k.company_name, k.supp_code
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
-- Portal: withdraw a request that is still waiting. { kyc_basic_info_sno, kyc_modified_sno, by }
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_nt_WithdrawKycChange
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @k  INT = TRY_CONVERT(INT, JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno'));
    DECLARE @m  INT = TRY_CONVERT(INT, JSON_VALUE(@jsonInput, '$.kyc_modified_sno'));
    DECLARE @by NVARCHAR(255) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.by'))), '');

    BEGIN TRY
        BEGIN TRAN;

        DECLARE @status CHAR(1), @approver VARCHAR(30);
        SELECT @status = status, @approver = current_approver_ecno
        FROM dbo.kyc_modified_data WITH (UPDLOCK, HOLDLOCK)
        WHERE kyc_modified_sno = @m AND kyc_basic_info_sno = @k;

        IF @status IS NULL
            THROW 58615, N'That request was not found.', 1;
        IF @status <> 'P'
            THROW 58615, N'Only a request that is still waiting for approval can be withdrawn.', 1;

        UPDATE dbo.kyc_modified_data
        SET status = 'C', decided_by = LEFT(@by, 30), decided_date = GETDATE(), decision_note = N'Withdrawn by the supplier'
        WHERE kyc_modified_sno = @m;

        COMMIT;

        SELECT m.kyc_modified_sno, m.version_no, m.status, @approver AS current_approver_ecno, k.company_name, k.supp_code
        FROM dbo.kyc_modified_data m
        JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = m.kyc_basic_info_sno
        WHERE m.kyc_modified_sno = @m;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

-- ------------------------------------------------------------
-- Portal: the logged-in supplier's own KYC.
--   RS1 what only the purchase team can change + the KYC snapshot + the hash the change form sends back
--       + the request waiting for approval (pending_*), if any
--   RS2 the supplier's requests, newest first (status, stage, decision, trail, old / new snapshots, files)
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
           CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', @snapshot), 2) AS snapshot_hash,
           p.kyc_modified_sno AS pending_sno, p.version_no AS pending_version, p.current_seq AS pending_stage_no,
           (SELECT COUNT(*) FROM OPENJSON(p.stages_json)) AS pending_stage_total,
           (SELECT JSON_VALUE(v.value, '$.stage') FROM OPENJSON(p.stages_json) v WHERE v.[key] = CAST(p.current_seq - 1 AS VARCHAR(10))) AS pending_stage_name,
           p.modified_date AS pending_since
    FROM dbo.kyc_basic_info k
    OUTER APPLY (SELECT TOP 1 s.supp_cat_name FROM dbo.supplier_category s
                 WHERE s.supp_cat_code = k.supplier_cat_code ORDER BY s.supp_cat_sno) sc
    OUTER APPLY (SELECT TOP 1 m.kyc_modified_sno, m.version_no, m.current_seq, m.stages_json, m.modified_date
                 FROM dbo.kyc_modified_data m
                 WHERE m.kyc_basic_info_sno = k.kyc_basic_info_sno AND m.status = 'P'
                 ORDER BY m.version_no DESC) p
    WHERE k.kyc_basic_info_sno = @k;

    SELECT m.kyc_modified_sno, m.version_no, m.reason, m.changed_sections, m.old_data, m.new_data,
           m.source, m.modified_by, m.modified_date,
           m.status, m.decided_date, m.decision_note, m.current_seq AS stage_no,
           (SELECT COUNT(*) FROM OPENJSON(m.stages_json)) AS stage_total,
           (SELECT JSON_VALUE(v.value, '$.stage') FROM OPENJSON(m.stages_json) v WHERE v.[key] = CAST(m.current_seq - 1 AS VARCHAR(10))) AS stage_name,
           (SELECT f.file_kind, f.file_name, f.file_path, f.file_size, f.uploaded_date
            FROM dbo.kyc_modified_data_file f
            WHERE f.kyc_modified_sno = m.kyc_modified_sno
            ORDER BY f.kyc_modified_file_sno
            FOR JSON PATH) AS files,
           (SELECT a.seq_no, a.stage_name, a.action, a.note, a.acted_date
            FROM dbo.kyc_modified_approval a
            WHERE a.kyc_modified_sno = m.kyc_modified_sno
            ORDER BY a.kyc_modified_approval_sno
            FOR JSON PATH) AS approvals
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
-- Staff: KYC change requests for one approver. { ecno }  (ecno = the staff ecno, or the login id of a non-staff approver)
--   RS1 requests waiting for ME (status P and my stage), oldest first
--   RS2 requests I have acted on (approved / rejected / still in later stages), newest first, 100 at most
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetKycChangeApprovals
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ecno VARCHAR(30) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ecno'))), '');
    IF @ecno IS NULL
        THROW 58622, N'The approver is missing.', 1;

    SELECT m.kyc_modified_sno, m.kyc_basic_info_sno, k.supp_code, k.company_name, k.pan_no,
           m.version_no, m.reason, m.changed_sections, m.old_data, m.new_data, m.modified_by, m.modified_date,
           m.status, m.decided_by, m.decided_date, m.decision_note,
           m.current_seq AS stage_no, m.current_approver_ecno,
           (SELECT COUNT(*) FROM OPENJSON(m.stages_json)) AS stage_total,
           (SELECT JSON_VALUE(v.value, '$.stage') FROM OPENJSON(m.stages_json) v WHERE v.[key] = CAST(m.current_seq - 1 AS VARCHAR(10))) AS stage_name,
           CAST(CASE WHEN m.status = 'P' AND UPPER(m.current_approver_ecno) = UPPER(@ecno) THEN 1 ELSE 0 END AS BIT) AS is_mine,
           (SELECT f.file_kind, f.file_name, f.file_path, f.file_size, f.uploaded_date
            FROM dbo.kyc_modified_data_file f
            WHERE f.kyc_modified_sno = m.kyc_modified_sno
            ORDER BY f.kyc_modified_file_sno
            FOR JSON PATH) AS files,
           (SELECT a.seq_no, a.stage_name, a.approver_ecno, a.action, a.note, a.acted_date
            FROM dbo.kyc_modified_approval a
            WHERE a.kyc_modified_sno = m.kyc_modified_sno
            ORDER BY a.kyc_modified_approval_sno
            FOR JSON PATH) AS approvals
    INTO #c
    FROM dbo.kyc_modified_data m
    JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = m.kyc_basic_info_sno
    WHERE (m.status = 'P' AND UPPER(m.current_approver_ecno) = UPPER(@ecno))
       OR EXISTS (SELECT 1 FROM dbo.kyc_modified_approval a WHERE a.kyc_modified_sno = m.kyc_modified_sno AND UPPER(a.approver_ecno) = UPPER(@ecno));

    SELECT * FROM #c WHERE is_mine = 1 ORDER BY modified_date;
    SELECT TOP (100) * FROM #c WHERE is_mine = 0 ORDER BY ISNULL(decided_date, modified_date) DESC;
END
GO

-- ------------------------------------------------------------
-- Staff: approve / reject one request. { kyc_modified_sno, ecno, action ('approve' | 'reject'), note }
-- ecno must be the approver the request is waiting for. A reject needs a note. Approving the LAST stage applies the change.
-- Returns one row: status (P still waiting / A applied / R rejected), the next approver and the supplier, for the alerts.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_nt_KycChangeAct
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @m      INT           = TRY_CONVERT(INT, JSON_VALUE(@jsonInput, '$.kyc_modified_sno'));
    DECLARE @ecno   VARCHAR(30)   = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ecno'))), '');
    DECLARE @action VARCHAR(10)   = LOWER(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.action'))), ''));
    DECLARE @note   NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.note'))), '');

    IF @m IS NULL OR @ecno IS NULL OR @action NOT IN ('approve', 'reject')
        THROW 58616, N'The request, the approver and the action (approve or reject) are required.', 1;
    IF @action = 'reject' AND @note IS NULL
        THROW 58619, N'Tell the supplier why the change is rejected.', 1;

    BEGIN TRY
        BEGIN TRAN;

        DECLARE @k INT, @status CHAR(1), @seq INT, @cur VARCHAR(30), @stages NVARCHAR(MAX), @payload NVARCHAR(MAX), @base_hash VARCHAR(64);
        SELECT @k = kyc_basic_info_sno, @status = status, @seq = current_seq, @cur = current_approver_ecno,
               @stages = stages_json, @payload = payload, @base_hash = base_hash
        FROM dbo.kyc_modified_data WITH (UPDLOCK, HOLDLOCK)
        WHERE kyc_modified_sno = @m;

        IF @k IS NULL
            THROW 58616, N'That change request was not found.', 1;
        IF @status <> 'P'
            THROW 58617, N'This request has already been decided or was withdrawn by the supplier.', 1;
        IF @cur IS NULL OR UPPER(@cur) <> UPPER(@ecno)
            THROW 58618, N'This request is not waiting for you.', 1;

        DECLARE @total INT = (SELECT COUNT(*) FROM OPENJSON(@stages));
        DECLARE @stage_name NVARCHAR(100) = (SELECT JSON_VALUE(v.value, '$.stage') FROM OPENJSON(@stages) v WHERE v.[key] = CAST(@seq - 1 AS VARCHAR(10)));

        INSERT dbo.kyc_modified_approval (kyc_modified_sno, seq_no, stage_name, approver_ecno, action, note)
        VALUES (@m, @seq, @stage_name, @ecno, CASE WHEN @action = 'approve' THEN 'A' ELSE 'R' END, @note);

        IF @action = 'reject'
        BEGIN
            UPDATE dbo.kyc_modified_data
            SET status = 'R', decided_by = @ecno, decided_date = GETDATE(), decision_note = @note
            WHERE kyc_modified_sno = @m;
        END
        ELSE IF @seq < @total
        BEGIN
            -- not the last stage: on to the next approver
            DECLARE @next VARCHAR(30) = (SELECT NULLIF(LTRIM(RTRIM(JSON_VALUE(v.value, '$.approver_ecno'))), '')
                                         FROM OPENJSON(@stages) v WHERE v.[key] = CAST(@seq AS VARCHAR(10)));
            IF @next IS NULL
                THROW 58620, N'The next approval stage has no approver. Ask an administrator to fix the approval workflow.', 1;
            UPDATE dbo.kyc_modified_data
            SET current_seq = @seq + 1, current_approver_ecno = @next
            WHERE kyc_modified_sno = @m;
        END
        ELSE
        BEGIN
            -- last stage: make the change live, unless the KYC moved on since the request was made
            DECLARE @locked INT;
            SELECT @locked = kyc_basic_info_sno FROM dbo.kyc_basic_info WITH (UPDLOCK, HOLDLOCK) WHERE kyc_basic_info_sno = @k;
            IF @base_hash IS NULL OR @base_hash <> CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', dbo.fn_nt_KycSnapshot(@k)), 2)
                THROW 58621, N'The supplier''s KYC was changed after this request was made, so it can no longer be applied. Reject it and ask the supplier to send the change again.', 1;

            DECLARE @apply_by VARCHAR(20) = LEFT(@ecno, 20);
            EXEC dbo.sp_nt_ApplyKycChange @jsonInput = @payload, @apply_by = @apply_by;

            UPDATE dbo.kyc_modified_data
            SET status = 'A', decided_by = @ecno, decided_date = GETDATE(), decision_note = @note,
                new_data = dbo.fn_nt_KycSnapshot(@k)     -- the real KYC now (new rows have their real ids)
            WHERE kyc_modified_sno = @m;
        END

        COMMIT;

        SELECT m.kyc_modified_sno, m.kyc_basic_info_sno, m.version_no, m.status, m.changed_sections,
               m.current_seq AS stage_no, @total AS stage_total,
               CASE WHEN m.status = 'P' THEN m.current_approver_ecno END AS next_approver_ecno,
               CASE WHEN m.status = 'P' THEN (SELECT JSON_VALUE(v.value, '$.stage') FROM OPENJSON(m.stages_json) v WHERE v.[key] = CAST(m.current_seq - 1 AS VARCHAR(10))) END AS next_stage_name,
               m.decision_note, k.supp_code, k.company_name
        FROM dbo.kyc_modified_data m
        JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = m.kyc_basic_info_sno
        WHERE m.kyc_modified_sno = @m;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

-- ------------------------------------------------------------
-- Staff: Supplier Status / KYC "View all" (backend-stpl sql/108/109, sql/92). RS1-RS6 exactly as before;
-- RS7 = the supplier's change requests, newest first, now with status, stage, decision and trail.
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
           m.status, m.decided_by, m.decided_date, m.decision_note, m.current_seq AS stage_no, m.current_approver_ecno,
           (SELECT COUNT(*) FROM OPENJSON(m.stages_json)) AS stage_total,
           (SELECT JSON_VALUE(v.value, '$.stage') FROM OPENJSON(m.stages_json) v WHERE v.[key] = CAST(m.current_seq - 1 AS VARCHAR(10))) AS stage_name,
           (SELECT f.file_kind, f.file_name, f.file_path, f.file_size, f.uploaded_date
            FROM dbo.kyc_modified_data_file f
            WHERE f.kyc_modified_sno = m.kyc_modified_sno
            ORDER BY f.kyc_modified_file_sno
            FOR JSON PATH) AS files,
           (SELECT a.seq_no, a.stage_name, a.approver_ecno, a.action, a.note, a.acted_date
            FROM dbo.kyc_modified_approval a
            WHERE a.kyc_modified_sno = m.kyc_modified_sno
            ORDER BY a.kyc_modified_approval_sno
            FOR JSON PATH) AS approvals
    FROM dbo.kyc_modified_data m
    WHERE m.kyc_basic_info_sno = @record_id
    ORDER BY m.version_no DESC;
END
GO

-- ------------------------------------------------------------
-- Seeds. "KYC > Supplier KYC change" shows up on the Approval Routing screen, routed to the KYC workflow by default; point it
-- at another entity there to give supplier changes their own approval stages.
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM dbo.approval_route_variant WHERE module_code = N'KYC' AND variant_code = N'SUPPLIER_CHANGE')
    INSERT dbo.approval_route_variant (module_code, variant_code, variant_label, sort_order)
    VALUES (N'KYC', N'SUPPLIER_CHANGE', N'Supplier KYC change', 2);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.approval_entity_route WHERE module_code = N'KYC' AND variant_code = N'SUPPLIER_CHANGE')
    INSERT dbo.approval_entity_route (module_code, variant_code, entity_code, modified_by)
    VALUES (N'KYC', N'SUPPLIER_CHANGE', N'KYC', N'system');
GO
