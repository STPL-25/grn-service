-- Rollback of sql/73_statutory_payments.sql (Non_trade_Dev). Removes statutory payments entirely - the file numbers they reserved
-- in payment_file_creation_no are kept (a number once issued to a bank is never reused).
UPDATE dbo.screens SET is_active = 'N' WHERE comp = 'StatutoryPaymentPage';   -- switched off, not deleted (grants stay harmlessly)
UPDATE dbo.screens SET display_order = 4 WHERE comp = 'Gstr2bPage';
UPDATE dbo.screens SET display_order = 5 WHERE comp = 'JournalsPage';
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_GetStatutoryBatches;
DROP PROCEDURE IF EXISTS dbo.sp_nt_SetStatutoryBatchFile;
DROP PROCEDURE IF EXISTS dbo.sp_nt_CreateStatutoryBatch;
DROP PROCEDURE IF EXISTS dbo.sp_nt_CancelStatutoryPayable;
DROP PROCEDURE IF EXISTS dbo.sp_nt_AddStatutoryPayable;
DROP PROCEDURE IF EXISTS dbo.sp_nt_GetStatutoryPayables;
DROP PROCEDURE IF EXISTS dbo.sp_nt_SyncStatutoryTds;
DROP PROCEDURE IF EXISTS dbo.sp_nt_UpsertStatutoryPayee;
DROP PROCEDURE IF EXISTS dbo.sp_nt_GetStatutoryPayees;
GO
DROP TABLE IF EXISTS dbo.statutory_batch_item;
DROP TABLE IF EXISTS dbo.statutory_payable;
DROP TABLE IF EXISTS dbo.statutory_batch;
DROP TABLE IF EXISTS dbo.statutory_payee;
GO
