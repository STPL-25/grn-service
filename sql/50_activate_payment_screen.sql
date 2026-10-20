-- 50: the Payment Page screen (screen_id 33) was switched off (is_active = 'N'), so no user could see it
-- even with permission. Switch it back on (Non_trade_Dev). Re-runnable.
UPDATE dbo.screens SET is_active = 'Y' WHERE comp = 'PaymentPage' AND is_active <> 'Y';
GO

-- It was filed under the 'Kyc' group (2); put it with the other accounts screens in the GRN group (6).
UPDATE dbo.screens SET group_id = 6, display_order = 24 WHERE comp = 'PaymentPage' AND group_id = 2;
GO
