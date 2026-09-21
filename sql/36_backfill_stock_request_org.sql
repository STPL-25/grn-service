-- ============================================================
-- Backfill: Manual store requisitions raised before 35_stock_request_org_from_items.sql
-- have NULL com/div/brn/dept, so Store Issue's org filter hides them.
-- Database: Non_Trade and Non_trade_Dev (MSSQL)
--
-- Applies the same rule as the fixed sp_nt_CreateStockRequest: the org of the
-- requested items (single com/div/brn bucket; dept only when every item agrees).
-- Only touches Manual rows whose com_sno is still NULL, and only when the items
-- resolve to exactly one com/div/brn — anything ambiguous is left alone.
-- Rows that already have an org (Auto-GRN) are never modified. Re-runnable.
--
-- Rollback (all touched rows were NULL/NULL/NULL/NULL before):
--   UPDATE dbo.nt_stock_requests SET com_sno=NULL, div_sno=NULL, brn_sno=NULL, dept_sno=NULL
--   WHERE request_sno IN (<the request_snos this script reported>) AND source_type = 'Manual';
-- ============================================================

;WITH item_org AS (
    SELECT
        ri.request_sno,
        COUNT(DISTINCT CONCAT(i.com_sno, '/', i.div_sno, '/', i.brn_sno)) AS buckets,
        MAX(i.com_sno) AS com_sno,
        MAX(i.div_sno) AS div_sno,
        MAX(i.brn_sno) AS brn_sno,
        CASE WHEN COUNT(DISTINCT ISNULL(i.dept_sno, -1)) = 1 THEN MAX(i.dept_sno) END AS dept_sno
    FROM dbo.nt_stock_request_items ri
    JOIN dbo.nt_inventory_items i ON i.item_sno = ri.item_sno
    GROUP BY ri.request_sno
)
UPDATE r
SET r.com_sno  = o.com_sno,
    r.div_sno  = o.div_sno,
    r.brn_sno  = o.brn_sno,
    r.dept_sno = o.dept_sno
FROM dbo.nt_stock_requests r
JOIN item_org o ON o.request_sno = r.request_sno
WHERE r.source_type = 'Manual'
  AND r.com_sno IS NULL
  AND o.buckets = 1
  AND o.com_sno IS NOT NULL;

PRINT CONCAT('Backfilled ', @@ROWCOUNT, ' manual requisition(s).');
GO
