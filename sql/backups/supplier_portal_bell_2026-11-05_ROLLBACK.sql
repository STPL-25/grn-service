-- Rollback for sql/88_supplier_portal_bell.sql.
-- Drops the two procedures and the event log. Notifications already created stay in nt_notifications (they expire after 24h);
-- the grn-service job (src/supplier/supplierEvents.job.js) logs "run sql/88" once and stops announcing until this is re-applied.
IF OBJECT_ID('dbo.sp_nt_GetPendingSupplierEvents', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetPendingSupplierEvents;
GO
IF OBJECT_ID('dbo.sp_nt_MarkSupplierEventsDelivered', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_MarkSupplierEventsDelivered;
GO
IF OBJECT_ID('dbo.nt_supplier_event_log', 'U') IS NOT NULL DROP TABLE dbo.nt_supplier_event_log;
GO
