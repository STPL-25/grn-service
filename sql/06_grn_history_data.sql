-- ============================================================
-- grn_history_data table
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- event_type: GRN Created / Re-GRN / Item Received / Item Rejected /
--             Waiver Requested / Waiver Approved / GRN Cancelled
-- po_basic_sno  : indexed — PO timeline
-- po_item_sno   : indexed — line timeline; NULL for header events
-- grn_basic_sno : FK -> dbo.grn_basic_info (see 05_grn_basic_info_v2.sql)
-- invoice_no    : snapshot, so invoice-level history survives gate-entry edits
-- qty           : quantity this event concerns
-- pending_qty_after : snapshot for display
-- ============================================================

IF OBJECT_ID('dbo.grn_history_data', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.grn_history_data (
        grn_history_sno   INT IDENTITY(1,1) PRIMARY KEY,
        event_type        VARCHAR(30)   NOT NULL,
        po_basic_sno       INT           NOT NULL,
        po_item_sno        INT           NULL,
        grn_basic_sno      INT           NULL,
        gate_entry_sno     INT           NULL,
        invoice_no         VARCHAR(100)  NULL,
        qty                DECIMAL(18,2) NULL,
        pending_qty_after  DECIMAL(18,2) NULL,
        from_status        VARCHAR(30)   NULL,
        to_status          VARCHAR(30)   NULL,
        reason             VARCHAR(100)  NULL,
        remarks            VARCHAR(500)  NULL,
        status_by          VARCHAR(50)   NULL,
        status_at          DATETIME      NOT NULL DEFAULT (GETDATE()),
        CONSTRAINT FK_grn_history_data_grn
            FOREIGN KEY (grn_basic_sno) REFERENCES dbo.grn_basic_info (grn_basic_sno)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_grn_history_data_po_basic_sno' AND object_id = OBJECT_ID('dbo.grn_history_data'))
    CREATE INDEX IX_grn_history_data_po_basic_sno ON dbo.grn_history_data (po_basic_sno);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_grn_history_data_po_item_sno' AND object_id = OBJECT_ID('dbo.grn_history_data'))
    CREATE INDEX IX_grn_history_data_po_item_sno ON dbo.grn_history_data (po_item_sno);
GO
