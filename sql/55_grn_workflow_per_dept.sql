-- ============================================================
-- 55_grn_workflow_per_dept.sql   (Non_trade_Dev)
--
-- GRN approval is looked up per company/division/branch/department (sp_nt_SubmitGRNForApproval,
-- sql/40) but no 'GRN' workflow existed, so every GRN auto-approved. This seeds one GRN workflow per
-- department that already has a Purchase Order workflow, with the same approver chain (minus the
-- PO-only 'can_select_quotation' flag). Edit approvers per dept on the Approval Workflows screen.
-- Departments without a GRN workflow still auto-approve (unchanged).
-- Re-runnable: a department that already has a GRN workflow is skipped.
-- ============================================================

DECLARE @wf INT = (SELECT TOP 1 workflow_id FROM dbo.approval_workflow_master
                   WHERE entity_type = 'GRN' AND workflow_code = 'WF_GRN');
IF @wf IS NULL
BEGIN
    INSERT INTO dbo.approval_workflow_master (workflow_name, workflow_code, entity_type, description, is_active, created_by)
    VALUES (N'GRN Approval Workflow', N'WF_GRN', 'GRN', N'Goods receipt approval, one chain per department', 'Y', 'system');
    SET @wf = SCOPE_IDENTITY();
END

DECLARE @src TABLE (src_id INT, com INT, div INT, brn INT, dept INT, nm NVARCHAR(200));
INSERT INTO @src
SELECT wt.workflow_types_id, wt.com_sno, wt.div_sno, wt.brn_sno, wt.dept_sno, wt.workflow_types_name
FROM dbo.workflow_types wt
JOIN dbo.approval_workflow_master a ON a.workflow_id = wt.workflow_id
WHERE a.entity_type = 'PurchaseOrder' AND a.is_active = 'Y' AND wt.is_active = 'Y'
  AND NOT EXISTS (SELECT 1 FROM dbo.workflow_types g
                  JOIN dbo.approval_workflow_master ga ON ga.workflow_id = g.workflow_id AND ga.entity_type = 'GRN'
                  WHERE g.is_active = 'Y' AND g.com_sno = wt.com_sno AND g.div_sno = wt.div_sno
                    AND g.brn_sno = wt.brn_sno AND g.dept_sno = wt.dept_sno);

DECLARE @id INT, @com INT, @div INT, @brn INT, @dept INT, @nm NVARCHAR(200), @new INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT src_id, com, div, brn, dept, nm FROM @src ORDER BY src_id;
OPEN c; FETCH NEXT FROM c INTO @id, @com, @div, @brn, @dept, @nm;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- several PO types can share one scope; only the first of each scope is copied
    IF NOT EXISTS (SELECT 1 FROM dbo.workflow_types g
                   JOIN dbo.approval_workflow_master ga ON ga.workflow_id = g.workflow_id AND ga.entity_type = 'GRN'
                   WHERE g.is_active = 'Y' AND g.com_sno = @com AND g.div_sno = @div AND g.brn_sno = @brn AND g.dept_sno = @dept)
    BEGIN
        INSERT INTO dbo.workflow_types (workflow_types_name, workflow_id, workflow_name, is_active, com_sno, div_sno, brn_sno, dept_sno,
                                        workflow_types_description, created_by)
        VALUES (CASE WHEN @nm LIKE N'%-PO' THEN LEFT(@nm, LEN(@nm) - 2) + N'GRN' ELSE N'GRN Approval' END,
                @wf, N'GRN Approval Workflow', 'Y', @com, @div, @brn, @dept, N'', 'system');
        SET @new = SCOPE_IDENTITY();

        INSERT INTO dbo.workflow_stage (workflow_types_id, stage_order_json, is_active, created_by)
        SELECT @new, REPLACE(stage_order_json, N',"can_select_quotation":"Y"', N''), 'Y', 'system'
        FROM dbo.workflow_stage WHERE workflow_types_id = @id AND is_active = 'Y';
    END
    FETCH NEXT FROM c INTO @id, @com, @div, @brn, @dept, @nm;
END
CLOSE c; DEALLOCATE c;
GO

SELECT wt.workflow_types_id, wt.workflow_types_name, wt.com_sno, wt.div_sno, wt.brn_sno, wt.dept_sno,
       (SELECT COUNT(*) FROM dbo.workflow_stage s WHERE s.workflow_types_id = wt.workflow_types_id) AS stage_rows
FROM dbo.workflow_types wt
JOIN dbo.approval_workflow_master a ON a.workflow_id = wt.workflow_id AND a.entity_type = 'GRN'
ORDER BY wt.workflow_types_id;
GO
