-- { stat_sno, reason, cancelled_by, hierarchy? } - an Open amount keyed in by hand. A TDS amount is not cancelled: it is owed.
CREATE   PROCEDURE dbo.sp_nt_CancelStatutoryPayable
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.stat_sno') AS INT), @reason NVARCHAR(200) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.reason'))), ''),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');
    IF @reason IS NULL THROW 57220, 'Give the reason.', 1;
    UPDATE s SET status = 'Cancelled', cancel_reason = @reason
    FROM dbo.statutory_payable s
    WHERE s.stat_sno = @id AND s.status = 'Open' AND s.source_type = 'MANUAL'
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = s.com_sno AND (h.div_sno IS NULL OR h.div_sno = s.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = s.brn_sno)));
    IF @@ROWCOUNT = 0 THROW 57221, 'Only an open amount keyed in by hand, inside your access, can be cancelled.', 1;
    SELECT @id AS stat_sno;
END