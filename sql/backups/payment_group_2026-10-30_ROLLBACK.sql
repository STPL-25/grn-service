-- Rolls back sql/74_payment_group.sql. Payments keep everything else; only the group tie is removed.
IF OBJECT_ID('dbo.sp_nt_GetPaymentGroupMap', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_GetPaymentGroupMap;
GO
IF OBJECT_ID('dbo.sp_nt_CreatePaymentGroup', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_CreatePaymentGroup;
GO
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_payment_info_group') ALTER TABLE dbo.payment_info DROP CONSTRAINT FK_payment_info_group;
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_payment_info_group' AND object_id = OBJECT_ID('dbo.payment_info')) DROP INDEX IX_payment_info_group ON dbo.payment_info;
GO
IF COL_LENGTH('dbo.payment_info', 'group_sno') IS NOT NULL ALTER TABLE dbo.payment_info DROP COLUMN group_sno;
GO
IF OBJECT_ID('dbo.payment_group', 'U') IS NOT NULL DROP TABLE dbo.payment_group;
GO
