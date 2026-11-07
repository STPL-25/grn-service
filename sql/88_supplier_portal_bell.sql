-- sql/88: bell notifications on the /Supplier portal for DEBIT NOTES, CREDIT NOTES and PAYMENTS.
--
-- Why a sweep: a debit / credit note is inserted by at least three different stored procedures (the manual Debit Note screen,
-- sp_nt_GRN_RaiseAutoNotes inside sp_nt_CreateGRN, and the asset-return path in sp_nt_AssetRequestAction), and a payment changes
-- state in several routes. Hooking every call site would miss one sooner or later, so grn-service runs a small job
-- (src/supplier/supplierEvents.job.js) that asks THIS procedure what is new and posts one bell notification per supplier event
-- through notification-service (recipient "SUPP:<kyc_basic_info_sno>", read by the portal's bell).
--
-- Events - they mirror exactly what the portal itself lists (sp_nt_GetDebitNotesForSupplier / GetCreditNotesForSupplier /
-- GetPaymentsForSupplier), so the bell never announces something the supplier cannot then open:
--   DEBIT_NOTE     a debit note raised for the supplier           (debit_note_basic_info, is_active = 'Y')
--   CREDIT_NOTE    a credit note raised for the supplier          (credit_note_basic_info, is_active = 'Y')
--   PAY_SCHEDULED  a payment reached 'Approved'  (portal: "Scheduled")
--   PAY_PAID       a payment reached 'Processed' (portal: "Paid")
-- A payment first seen already 'Processed' (approved and paid between two sweeps) is announced once, as paid: its PAY_SCHEDULED
-- row is written silently.
--
-- nt_supplier_event_log is the memory of what was already announced: UNIQUE (event_kind, ref_sno) makes registering idempotent,
-- delivered_at marks success, claimed_at is a 5-minute lease so a second grn-service instance does not announce the same event
-- while the first is mid-send (a failed send is retried after the lease; events older than 48h are no longer retried).
--
-- SEEDING: when the table is first created, everything that already exists is logged as silent + delivered, so switching this on
-- does not announce a supplier's whole history. Only events created after this script runs notify.
--
-- Re-runnable.  Rollback: sql/backups/supplier_portal_bell_2026-11-05_ROLLBACK.sql (drops the 2 procedures + the table).

IF OBJECT_ID('dbo.nt_supplier_event_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_supplier_event_log (
        event_sno    INT IDENTITY(1,1) PRIMARY KEY,
        event_kind   VARCHAR(20) NOT NULL,
        ref_sno      INT         NOT NULL,            -- debit_note_sno | credit_note_sno | payment_sno
        vendor_sno   INT         NOT NULL,            -- kyc_basic_info_sno
        detected_at  DATETIME    NOT NULL CONSTRAINT DF_nt_supplier_event_log_detected DEFAULT GETDATE(),
        claimed_at   DATETIME    NULL,
        delivered_at DATETIME    NULL,
        silent       BIT         NOT NULL CONSTRAINT DF_nt_supplier_event_log_silent DEFAULT 0,
        CONSTRAINT UQ_nt_supplier_event_log UNIQUE (event_kind, ref_sno),
        CONSTRAINT CK_nt_supplier_event_log_kind CHECK (event_kind IN ('DEBIT_NOTE', 'CREDIT_NOTE', 'PAY_SCHEDULED', 'PAY_PAID'))
    );

    -- Seed: what exists today is history, not news.
    INSERT INTO dbo.nt_supplier_event_log (event_kind, ref_sno, vendor_sno, delivered_at, silent)
    SELECT 'DEBIT_NOTE', n.debit_note_sno, n.vendor_sno, GETDATE(), 1
    FROM dbo.debit_note_basic_info n WHERE n.is_active = 'Y' AND n.vendor_sno IS NOT NULL;

    INSERT INTO dbo.nt_supplier_event_log (event_kind, ref_sno, vendor_sno, delivered_at, silent)
    SELECT 'CREDIT_NOTE', n.credit_note_sno, n.vendor_sno, GETDATE(), 1
    FROM dbo.credit_note_basic_info n WHERE n.is_active = 'Y' AND n.vendor_sno IS NOT NULL;

    INSERT INTO dbo.nt_supplier_event_log (event_kind, ref_sno, vendor_sno, delivered_at, silent)
    SELECT 'PAY_SCHEDULED', p.payment_sno, p.vendor_sno, GETDATE(), 1
    FROM dbo.payment_info p WHERE p.is_active = 'Y' AND p.vendor_sno IS NOT NULL AND p.status IN ('Approved', 'Processed');

    INSERT INTO dbo.nt_supplier_event_log (event_kind, ref_sno, vendor_sno, delivered_at, silent)
    SELECT 'PAY_PAID', p.payment_sno, p.vendor_sno, GETDATE(), 1
    FROM dbo.payment_info p WHERE p.is_active = 'Y' AND p.vendor_sno IS NOT NULL AND p.status = 'Processed';
END
GO

-- ============================================================
-- sp_nt_GetPendingSupplierEvents
-- No input. Registers any new supplier event, then claims and returns the ones still to be announced (one row each, with what
-- the message needs). An event whose note / payment has since gone inactive comes back with a NULL ref_no - the job marks it
-- delivered without sending.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPendingSupplierEvents
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRAN;

    -- One sweeper at a time: registering + claiming must not interleave between two instances.
    DECLARE @lock INT;
    EXEC @lock = sp_getapplock @Resource = 'nt_supplier_events', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 5000;
    IF @lock < 0
    BEGIN
        ROLLBACK TRAN;
        RETURN;   -- someone else is sweeping; nothing to do this round
    END

    -- 1) Register what appeared since the last sweep (same filters as the portal lists).
    INSERT INTO dbo.nt_supplier_event_log (event_kind, ref_sno, vendor_sno)
    SELECT 'DEBIT_NOTE', n.debit_note_sno, n.vendor_sno
    FROM dbo.debit_note_basic_info n
    WHERE n.is_active = 'Y' AND n.vendor_sno IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.nt_supplier_event_log l WHERE l.event_kind = 'DEBIT_NOTE' AND l.ref_sno = n.debit_note_sno);

    INSERT INTO dbo.nt_supplier_event_log (event_kind, ref_sno, vendor_sno)
    SELECT 'CREDIT_NOTE', n.credit_note_sno, n.vendor_sno
    FROM dbo.credit_note_basic_info n
    WHERE n.is_active = 'Y' AND n.vendor_sno IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.nt_supplier_event_log l WHERE l.event_kind = 'CREDIT_NOTE' AND l.ref_sno = n.credit_note_sno);

    INSERT INTO dbo.nt_supplier_event_log (event_kind, ref_sno, vendor_sno)
    SELECT 'PAY_SCHEDULED', p.payment_sno, p.vendor_sno
    FROM dbo.payment_info p
    WHERE p.is_active = 'Y' AND p.vendor_sno IS NOT NULL AND p.status = 'Approved'
      AND NOT EXISTS (SELECT 1 FROM dbo.nt_supplier_event_log l WHERE l.event_kind = 'PAY_SCHEDULED' AND l.ref_sno = p.payment_sno);

    INSERT INTO dbo.nt_supplier_event_log (event_kind, ref_sno, vendor_sno)
    SELECT 'PAY_PAID', p.payment_sno, p.vendor_sno
    FROM dbo.payment_info p
    WHERE p.is_active = 'Y' AND p.vendor_sno IS NOT NULL AND p.status = 'Processed'
      AND NOT EXISTS (SELECT 1 FROM dbo.nt_supplier_event_log l WHERE l.event_kind = 'PAY_PAID' AND l.ref_sno = p.payment_sno);

    -- A payment first seen already paid was never "scheduled" as far as the supplier is concerned: record that quietly so a
    -- later sweep cannot announce a stale "scheduled" after the "paid".
    INSERT INTO dbo.nt_supplier_event_log (event_kind, ref_sno, vendor_sno, delivered_at, silent)
    SELECT 'PAY_SCHEDULED', p.payment_sno, p.vendor_sno, GETDATE(), 1
    FROM dbo.payment_info p
    WHERE p.is_active = 'Y' AND p.vendor_sno IS NOT NULL AND p.status = 'Processed'
      AND NOT EXISTS (SELECT 1 FROM dbo.nt_supplier_event_log l WHERE l.event_kind = 'PAY_SCHEDULED' AND l.ref_sno = p.payment_sno);

    -- 2) Claim what is still to be announced (not delivered, recent, not claimed by someone mid-send).
    DECLARE @claimed TABLE (event_sno INT PRIMARY KEY);
    UPDATE l SET claimed_at = GETDATE()
    OUTPUT inserted.event_sno INTO @claimed (event_sno)
    FROM dbo.nt_supplier_event_log l
    WHERE l.delivered_at IS NULL
      AND l.detected_at > DATEADD(HOUR, -48, GETDATE())
      AND (l.claimed_at IS NULL OR l.claimed_at < DATEADD(MINUTE, -5, GETDATE()));

    -- 3) What each message needs.
    SELECT l.event_sno, l.event_kind, l.ref_sno, l.vendor_sno,
           COALESCE(dn.debit_note_no, cn.credit_note_no, p.payment_no)                 AS ref_no,
           COALESCE(dn.total_amount, cn.total_amount, ISNULL(p.net_paid, p.amount))   AS amount,
           COALESCE(dn.remarks, cn.remarks)                                           AS remarks,
           COALESCE(dpo.po_df_no, cpo.po_df_no)                                       AS po_no,
           p.payment_type,
           p.mode,
           CONVERT(VARCHAR(11), p.adv_due_date, 106)                                  AS planned_for,
           CONVERT(VARCHAR(11), p.processed_at, 106)                                  AS paid_on
    FROM dbo.nt_supplier_event_log l
    JOIN @claimed c ON c.event_sno = l.event_sno
    LEFT JOIN dbo.debit_note_basic_info  dn  ON l.event_kind = 'DEBIT_NOTE'  AND dn.debit_note_sno  = l.ref_sno AND dn.is_active = 'Y'
    LEFT JOIN dbo.po_request_info        dpo ON dpo.po_basic_sno = dn.po_basic_sno
    LEFT JOIN dbo.credit_note_basic_info cn  ON l.event_kind = 'CREDIT_NOTE' AND cn.credit_note_sno = l.ref_sno AND cn.is_active = 'Y'
    LEFT JOIN dbo.po_request_info        cpo ON cpo.po_basic_sno = cn.po_basic_sno
    LEFT JOIN dbo.payment_info           p   ON l.event_kind IN ('PAY_SCHEDULED', 'PAY_PAID') AND p.payment_sno = l.ref_sno AND p.is_active = 'Y'
    ORDER BY l.event_sno;

    COMMIT TRAN;
END;
GO

-- ============================================================
-- sp_nt_MarkSupplierEventsDelivered
-- @jsonInput: { event_snos: [1,2,3] }  -> { marked }
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_MarkSupplierEventsDelivered
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE l SET delivered_at = GETDATE()
    FROM dbo.nt_supplier_event_log l
    WHERE l.delivered_at IS NULL
      AND l.event_sno IN (SELECT TRY_CAST([value] AS INT) FROM OPENJSON(@jsonInput, '$.event_snos') WHERE TRY_CAST([value] AS INT) IS NOT NULL);

    SELECT @@ROWCOUNT AS marked;
END;
GO
