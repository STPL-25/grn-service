-- 49: give KTM1148 the Payment screen (Non_trade_Dev). Re-runnable.
DECLARE @screen_id INT, @json NVARCHAR(200);
SELECT @screen_id = screen_id FROM dbo.screens WHERE comp = 'PaymentPage';
IF @screen_id IS NULL THROW 53701, 'PaymentPage screen not found.', 1;
SET @json = N'{"ecno":"KTM1148","screen_id":' + CAST(@screen_id AS VARCHAR(10)) + N',"permission_ids":[2,3,4,5]}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
GO
