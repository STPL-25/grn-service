-- ============================================================
-- 61_tds_more_sections.sql   (Non_trade_Dev)
-- Seeds additional TDS sections into tds_section_master (insert-only: existing rows are never changed).
-- 194J / 194I keep their current rows (professional fees 10%, land/building rent 10%); the lower-rate
-- variants are separate sections: 194J-T technical services 2%, 194I-PM plant & machinery rent 2%.
-- Rates / limits are starting values - confirm with the accounts team and edit in Masters > TDS Section.
-- 195 (non-resident) has no fixed rate: the DTAA rate is entered per case, so 0 is seeded and it is left Inactive.
-- Re-runnable.
-- ============================================================
MERGE dbo.tds_section_master AS t
USING (VALUES
  ('194J-T', N'Technical services / call centre (2%)',                 2.0,  2.0, 20, 0,        50000,   'N', 'Y'),
  ('194I-PM',N'Rent of plant, machinery and equipment',                2.0,  2.0, 20, 0,        600000,  'N', 'Y'),
  ('194M',   N'Contract / commission / professional - individual or HUF not under audit', 2.0, 2.0, 20, 0, 5000000, 'N', 'Y'),
  ('194O',   N'E-commerce operator paying participants',               0.1,  0.1, 5,  0,        500000,  'N', 'Y'),
  ('194R',   N'Benefits or perquisites (gifts, trips to dealers)',     10.0, 10.0, 20, 0,        20000,   'N', 'Y'),
  ('194D',   N'Insurance commission',                                  2.0,  2.0, 20, 0,        20000,   'N', 'Y'),
  ('194IA',  N'Purchase of immovable property',                        1.0,  1.0, 20, 5000000,  0,       'N', 'Y'),
  ('194T',   N'Payments to partners of a firm',                        10.0, 10.0, 20, 0,        20000,   'N', 'Y'),
  ('194S',   N'Virtual digital assets',                                1.0,  1.0, 20, 0,        10000,   'N', 'Y'),
  ('194LA',  N'Compensation on acquisition of immovable property',     10.0, 10.0, 20, 500000,  0,       'N', 'Y'),
  ('195',    N'Payments to non-residents (rate per DTAA - set per case)', 0.0, 0.0, 20, 0,       0,       'N', 'N')
) AS s(section_code, description, rate_individual, rate_other, rate_no_pan, single_threshold, annual_threshold, excess_only, is_active)
ON t.section_code = s.section_code
WHEN NOT MATCHED THEN INSERT (section_code, description, rate_individual, rate_other, rate_no_pan, single_threshold, annual_threshold, excess_only, is_active, modified_by)
     VALUES (s.section_code, s.description, s.rate_individual, s.rate_other, s.rate_no_pan, s.single_threshold, s.annual_threshold, s.excess_only, s.is_active, 'system');
GO
