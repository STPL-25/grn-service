-- ============================================================
-- 41_accounting_journal.sql   (Non_trade_Dev ONLY)
--
-- Phase 2: accounting journal posted when a GRN is finally approved.
--
--   Dr  <account head of the item's sub-category>   (Inventory / Purchases-Consumables / Suspense)
--   Cr  GRNI Clearing                               (Goods Received Not Invoiced)
--
-- Value of a line = accepted qty x PO agreed unit price x (1 - PO discount %).  GST is NOT posted here
-- (a GRN has no tax invoice); input GST + supplier payable are posted at invoice booking (phase 3),
-- which will debit GRNI Clearing to clear it.
-- Accepted qty = received - rejected - held (excess above PO is journalled only once accepted).
-- Posting is idempotent and incremental: sp_nt_PostGRNJournal journals only the qty not yet journalled
-- for each GRN line (tracked on acct_journal_line.qty), so it can be called again after held excess is
-- accepted. A sub-category with no account head posts to 'Suspense - Unmapped' and is flagged.
-- Journals are never edited; corrections are made by reversal.
-- Re-runnable.
-- ============================================================

-- ── chart of accounts ───────────────────────────────────────────────────────
IF OBJECT_ID('dbo.acct_account_head', 'U') IS NULL
CREATE TABLE dbo.acct_account_head (
    head_sno    INT IDENTITY(1,1) PRIMARY KEY,
    head_code   VARCHAR(20)  NOT NULL UNIQUE,
    head_name   NVARCHAR(120) NOT NULL,
    head_type   VARCHAR(12)  NOT NULL CHECK (head_type IN ('ASSET','LIABILITY','EXPENSE','INCOME','EQUITY')),
    system_key  VARCHAR(30)  NULL,                  -- fixed role used by posting code
    is_active   CHAR(1) NOT NULL DEFAULT 'Y',
    created_by  VARCHAR(30) NULL,
    created_at  DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_acct_account_head_system_key')
    CREATE UNIQUE INDEX UX_acct_account_head_system_key ON dbo.acct_account_head (system_key) WHERE system_key IS NOT NULL;
GO

MERGE dbo.acct_account_head AS t
USING (VALUES
  ('1100', N'Inventory - Stock',                'ASSET',     'INVENTORY'),
  ('1150', N'Advance to Suppliers',             'ASSET',     'ADVANCE_SUPPLIER'),
  ('1210', N'Input CGST',                       'ASSET',     'INPUT_CGST'),
  ('1220', N'Input SGST',                       'ASSET',     'INPUT_SGST'),
  ('1230', N'Input IGST',                       'ASSET',     'INPUT_IGST'),
  ('1900', N'Suspense - Unmapped',              'ASSET',     'SUSPENSE'),
  ('2100', N'Supplier Payable',                 'LIABILITY', 'SUPPLIER_PAYABLE'),
  ('2150', N'GRNI Clearing (Goods Received Not Invoiced)', 'LIABILITY', 'GRNI'),
  ('2210', N'TDS Payable',                      'LIABILITY', 'TDS_PAYABLE'),
  ('2300', N'Bank',                             'ASSET',     'BANK'),
  ('5100', N'Purchases / Consumables Expense',  'EXPENSE',   'PURCHASE_EXPENSE')
) AS s(head_code, head_name, head_type, system_key)
ON t.head_code = s.head_code
WHEN NOT MATCHED THEN INSERT (head_code, head_name, head_type, system_key, created_by)
     VALUES (s.head_code, s.head_name, s.head_type, s.system_key, 'system');
GO

-- sub-category -> account head (Accounts maps; blank = Suspense)
IF COL_LENGTH('dbo.subcategory_master', 'subcat_account_head_sno') IS NULL AND COL_LENGTH('dbo.subcategory_master', 'account_head_sno') IS NULL
    ALTER TABLE dbo.subcategory_master ADD subcat_account_head_sno INT NULL;
IF COL_LENGTH('dbo.subcategory_master', 'account_head_sno') IS NOT NULL
    EXEC sp_rename 'dbo.subcategory_master.account_head_sno', 'subcat_account_head_sno', 'COLUMN';   -- renamed: product_master has its own account_head_sno
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_subcategory_account_head')
    ALTER TABLE dbo.subcategory_master ADD CONSTRAINT FK_subcategory_account_head
        FOREIGN KEY (subcat_account_head_sno) REFERENCES dbo.acct_account_head (head_sno);
GO

-- ── journal ─────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.acct_journal', 'U') IS NULL
CREATE TABLE dbo.acct_journal (
    journal_sno   INT IDENTITY(1,1) PRIMARY KEY,
    journal_no    VARCHAR(30) NULL,
    journal_date  DATE NOT NULL,
    source_type   VARCHAR(20) NOT NULL,            -- GRN (later: INVOICE, PAYMENT, DEBIT_NOTE ...)
    source_sno    INT NOT NULL,
    narration     NVARCHAR(300) NULL,
    com_sno INT NULL, div_sno INT NULL, brn_sno INT NULL, dept_sno INT NULL,
    status        VARCHAR(10) NOT NULL DEFAULT 'Posted' CHECK (status IN ('Posted','Reversed')),
    reverses_journal_sno INT NULL,
    created_by    VARCHAR(30) NULL,
    created_at    DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF OBJECT_ID('dbo.acct_journal_line', 'U') IS NULL
CREATE TABLE dbo.acct_journal_line (
    line_sno     INT IDENTITY(1,1) PRIMARY KEY,
    journal_sno  INT NOT NULL REFERENCES dbo.acct_journal (journal_sno),
    head_sno     INT NOT NULL REFERENCES dbo.acct_account_head (head_sno),
    debit        DECIMAL(18,2) NOT NULL DEFAULT 0,
    credit       DECIMAL(18,2) NOT NULL DEFAULT 0,
    vendor_sno   INT NULL,
    grn_item_sno INT NULL,
    qty          DECIMAL(18,4) NULL,               -- GRN qty this line journals (for incremental posting)
    subcat_sno   INT NULL,
    is_suspense  BIT NOT NULL DEFAULT 0,
    CONSTRAINT CK_acct_journal_line_one_side CHECK ((debit = 0 AND credit >= 0) OR (credit = 0 AND debit >= 0))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_acct_journal_source')
    CREATE INDEX IX_acct_journal_source ON dbo.acct_journal (source_type, source_sno);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_acct_journal_line_journal')
    CREATE INDEX IX_acct_journal_line_journal ON dbo.acct_journal_line (journal_sno);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_acct_journal_line_grn_item')
    CREATE INDEX IX_acct_journal_line_grn_item ON dbo.acct_journal_line (grn_item_sno) WHERE grn_item_sno IS NOT NULL;
GO

-- ── post a GRN's journal (incremental, idempotent) ──────────────────────────
-- @jsonInput: { grn_basic_sno, created_by }
-- Only posts for an Approved (or legacy 'Received') GRN. Returns the journal row, or nothing if no new qty.
CREATE OR ALTER PROCEDURE dbo.sp_nt_PostGRNJournal
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn INT = JSON_VALUE(@jsonInput, '$.grn_basic_sno'),
            @by  VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by');

    DECLARE @status VARCHAR(20), @grn_no INT, @rdate DATE, @vendor INT, @created DATE,
            @com INT, @div INT, @brn INT, @dept INT;
    SELECT @status = status, @grn_no = grn_no, @rdate = received_date, @vendor = vendor_sno, @created = created_date,
           @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno
    FROM dbo.grn_basic_info WHERE grn_basic_sno = @grn AND is_active = 'Y';

    IF @status IS NULL THROW 53301, 'GRN not found.', 1;
    IF @status NOT IN ('Approved', 'Received') THROW 53302, 'A journal is posted only for an approved GRN.', 1;

    DECLARE @inv INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'INVENTORY'),
            @exp INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'PURCHASE_EXPENSE'),
            @sus INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'SUSPENSE'),
            @grni INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'GRNI');
    IF @inv IS NULL OR @sus IS NULL OR @grni IS NULL OR @exp IS NULL THROW 53303, 'System account heads are missing.', 1;

    -- lines with qty not yet journalled
    DECLARE @new TABLE (grn_item_sno INT, subcat_sno INT, head_sno INT, is_suspense BIT, qty DECIMAL(18,4), amount DECIMAL(18,2));
    INSERT INTO @new (grn_item_sno, subcat_sno, head_sno, is_suspense, qty, amount)
    SELECT x.grn_item_sno, x.subcat_sno,
           ISNULL(x.mapped_head, @sus), CASE WHEN x.mapped_head IS NULL THEN 1 ELSE 0 END,
           x.delta_qty, ROUND(x.delta_qty * x.rate, 2)
    FROM (
        SELECT gi.grn_item_sno, pm.subcat_sno, COALESCE(pm.account_head_sno, sc.subcat_account_head_sno) AS mapped_head,   -- product head first, then sub-category
               (ISNULL(gi.received_qty, 0) - ISNULL(gi.rejected_qty, 0) - ISNULL(gi.hold_qty, 0))
                 - ISNULL((SELECT SUM(jl.qty) FROM dbo.acct_journal_line jl
                           JOIN dbo.acct_journal j ON j.journal_sno = jl.journal_sno AND j.status = 'Posted'
                           WHERE jl.grn_item_sno = gi.grn_item_sno AND jl.debit > 0), 0) AS delta_qty,
               ISNULL(pi.agreed_unit_price, ISNULL(gi.po_unit_price, 0)) * (1 - ISNULL(pi.discount_pct, 0) / 100.0) AS rate
        FROM dbo.grn_item_details gi
        LEFT JOIN dbo.po_item_details pi ON pi.po_item_sno = gi.po_item_sno
        LEFT JOIN dbo.product_master pm ON pm.prod_sno = gi.prod_sno
        LEFT JOIN dbo.subcategory_master sc ON sc.subcat_sno = pm.subcat_sno
        WHERE gi.grn_basic_sno = @grn AND gi.is_active = 'Y'
    ) x
    WHERE x.delta_qty > 0;

    IF NOT EXISTS (SELECT 1 FROM @new WHERE amount > 0)
    BEGIN
        SELECT CAST(NULL AS INT) AS journal_sno, CAST(0 AS DECIMAL(18,2)) AS total_amount, CAST(0 AS BIT) AS has_suspense;
        RETURN;
    END

    DECLARE @journal INT, @total DECIMAL(18,2) = (SELECT SUM(amount) FROM @new WHERE amount > 0);
    DECLARE @label VARCHAR(30) = 'GRN-' + CAST(YEAR(@created) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(@grn_no AS VARCHAR(6)), 6);

    BEGIN TRANSACTION;
    BEGIN TRY
        INSERT INTO dbo.acct_journal (journal_date, source_type, source_sno, narration, com_sno, div_sno, brn_sno, dept_sno, created_by)
        VALUES (@rdate, 'GRN', @grn, N'Goods received ' + @label, @com, @div, @brn, @dept, @by);
        SET @journal = SCOPE_IDENTITY();
        UPDATE dbo.acct_journal SET journal_no = 'JV-' + RIGHT('000000' + CAST(@journal AS VARCHAR(6)), 6) WHERE journal_sno = @journal;

        -- Dr: one line per GRN item (keeps the per-line qty trail)
        INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno, grn_item_sno, qty, subcat_sno, is_suspense)
        SELECT @journal, head_sno, amount, 0, @vendor, grn_item_sno, qty, subcat_sno, is_suspense
        FROM @new WHERE amount > 0;

        -- Cr: GRNI Clearing for the total
        INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno)
        VALUES (@journal, @grni, 0, @total, @vendor);

        IF (SELECT SUM(debit) - SUM(credit) FROM dbo.acct_journal_line WHERE journal_sno = @journal) <> 0
            THROW 53304, 'Journal is not balanced.', 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT @journal AS journal_sno, @total AS total_amount,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM @new WHERE is_suspense = 1 AND amount > 0) THEN 1 ELSE 0 END AS BIT) AS has_suspense;
END
GO

-- ── map a sub-category to an account head ───────────────────────────────────
-- @jsonInput: { subcat_sno, head_sno, modified_by }
CREATE OR ALTER PROCEDURE dbo.sp_nt_SetSubcategoryAccountHead
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sc INT = JSON_VALUE(@jsonInput, '$.subcat_sno'), @h INT = JSON_VALUE(@jsonInput, '$.head_sno'),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.modified_by');
    IF NOT EXISTS (SELECT 1 FROM dbo.subcategory_master WHERE subcat_sno = @sc) THROW 53310, 'Sub-category not found.', 1;
    IF @h IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.acct_account_head WHERE head_sno = @h AND is_active = 'Y'
                                       AND head_type IN ('ASSET', 'EXPENSE') AND ISNULL(system_key, '') NOT IN ('SUSPENSE', 'BANK', 'ADVANCE_SUPPLIER'))
        THROW 53311, 'Choose an Inventory or Expense account head.', 1;
    UPDATE dbo.subcategory_master SET subcat_account_head_sno = @h, subcat_modified_by = @by, subcat_modified_date = GETDATE() WHERE subcat_sno = @sc;
    SELECT subcat_sno, subcat_name, subcat_account_head_sno AS account_head_sno FROM dbo.subcategory_master WHERE subcat_sno = @sc;
END
GO

-- ── reads ───────────────────────────────────────────────────────────────────
-- @jsonInput: { source_type?, source_sno?, suspense_only? }
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetJournals
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @st VARCHAR(20) = NULLIF(JSON_VALUE(@jsonInput, '$.source_type'), ''),
            @ss INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.source_sno') AS INT),
            @sus BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.suspense_only') IN ('1', 'true') THEN 1 ELSE 0 END;

    SELECT j.journal_sno, j.journal_no, CONVERT(VARCHAR(10), j.journal_date, 120) AS journal_date, j.source_type, j.source_sno,
           j.narration, j.status, j.com_sno, j.div_sno, j.brn_sno, j.dept_sno,
           l.line_sno, h.head_code, h.head_name, l.debit, l.credit, l.vendor_sno, l.grn_item_sno, l.qty, l.subcat_sno, l.is_suspense
    FROM dbo.acct_journal j
    JOIN dbo.acct_journal_line l ON l.journal_sno = j.journal_sno
    JOIN dbo.acct_account_head h ON h.head_sno = l.head_sno
    WHERE (@st IS NULL OR j.source_type = @st) AND (@ss IS NULL OR j.source_sno = @ss)
      AND (@sus = 0 OR j.journal_sno IN (SELECT journal_sno FROM dbo.acct_journal_line WHERE is_suspense = 1))
    ORDER BY j.journal_sno DESC, l.line_sno;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetAccountHeads
AS
BEGIN
    SET NOCOUNT ON;
    SELECT head_sno, head_code, head_name, head_type, system_key FROM dbo.acct_account_head WHERE is_active = 'Y' ORDER BY head_code;
END
GO
