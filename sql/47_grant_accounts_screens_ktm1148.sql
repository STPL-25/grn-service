-- 47: give KTM1148 the Account Heads and GSTR-2B Reconciliation screens (Non_trade_Dev). Re-runnable.
DECLARE @screen_id INT, @json NVARCHAR(200);
SELECT @screen_id = screen_id FROM dbo.screens WHERE comp = 'AccountHeadsPage';
SET @json = N'{"ecno":"KTM1148","screen_id":' + CAST(@screen_id AS VARCHAR(10)) + N',"permission_ids":[2,3,4,5]}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
SELECT @screen_id = screen_id FROM dbo.screens WHERE comp = 'Gstr2bPage';
SET @json = N'{"ecno":"KTM1148","screen_id":' + CAST(@screen_id AS VARCHAR(10)) + N',"permission_ids":[2,3,4,5]}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
GO
