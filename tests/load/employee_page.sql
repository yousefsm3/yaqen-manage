-- one employee (random of 1,500) opens the invoices screen: page of 50 + exact count, under RLS
\set g random(2, 1500)
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0001-' || lpad(to_hex(:g::int), 12, '0') || '","role":"authenticated","aal":"aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT * FROM invoices WHERE company_id = '00000000-0000-0000-0000-00000000aaaa' ORDER BY updated_at DESC, id LIMIT 50;
SELECT count(*) FROM invoices WHERE company_id = '00000000-0000-0000-0000-00000000aaaa';
SELECT * FROM vehicles WHERE company_id = '00000000-0000-0000-0000-00000000aaaa' ORDER BY updated_at DESC, id LIMIT 50;
END;
