-- Rollback of sql/72_vendor_driven_consolidated_bill.sql (Non_trade_Dev).
-- Member invoices stay as ordinary invoices; only the grouping goes away.
IF OBJECT_ID('dbo.sp_nt_GetVendorBillConsolidations', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetVendorBillConsolidations;
GO
IF OBJECT_ID('dbo.sp_nt_CreateVendorBillConsolidation', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreateVendorBillConsolidation;
GO
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_invoice_info_consolidation')
    ALTER TABLE dbo.invoice_info DROP CONSTRAINT FK_invoice_info_consolidation;
GO
IF COL_LENGTH('dbo.invoice_info', 'consolidation_sno') IS NOT NULL
    ALTER TABLE dbo.invoice_info DROP COLUMN consolidation_sno;
GO
IF OBJECT_ID('dbo.vendor_bill_consolidation', 'U') IS NOT NULL DROP TABLE dbo.vendor_bill_consolidation;
GO
-- sp_nt_GetVendorDrivenBillableChildPOs: re-run sql/28_vendor_driven_billing.sql to restore the previous body.
