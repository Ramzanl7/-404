-- RBAC demo seed. Apply after 005_seed_data.sql and 006_rbac.sql.
-- All accounts are fictional and deliberately have no usable password hashes.
BEGIN;
INSERT INTO cinema.users(id,email,display_name) VALUES
 ('55555555-5555-4555-8555-555555555504','manager.demo@example.test','Мадина — управляющая'),
 ('55555555-5555-4555-8555-555555555505','cashier.demo@example.test','Ильяс — кассир'),
 ('55555555-5555-4555-8555-555555555506','editor.demo@example.test','Лейла — контент-менеджер'),
 ('55555555-5555-4555-8555-555555555507','projection.demo@example.test','Адам — оператор зала')
ON CONFLICT (id) DO NOTHING;

INSERT INTO cinema.user_role_assignments(user_id,role_id,cinema_id,assigned_by)
SELECT v.user_id,r.id,v.cinema_id,'55555555-5555-4555-8555-555555555503'::uuid
FROM (VALUES
 ('55555555-5555-4555-8555-555555555504'::uuid,'cinema_manager','11111111-1111-4111-8111-111111111101'::uuid),
 ('55555555-5555-4555-8555-555555555505'::uuid,'cashier','11111111-1111-4111-8111-111111111101'::uuid),
 ('55555555-5555-4555-8555-555555555506'::uuid,'content_editor','11111111-1111-4111-8111-111111111102'::uuid),
 ('55555555-5555-4555-8555-555555555507'::uuid,'projectionist','11111111-1111-4111-8111-111111111103'::uuid)
) AS v(user_id,role_code,cinema_id)
JOIN cinema.roles r ON r.code=v.role_code
WHERE NOT EXISTS (
 SELECT 1 FROM cinema.user_role_assignments a
 WHERE a.user_id=v.user_id AND a.role_id=r.id AND a.cinema_id=v.cinema_id AND a.revoked_at IS NULL
);

-- Staff may also buy personal tickets.
INSERT INTO cinema.user_role_assignments(user_id,role_id)
SELECT u.id,r.id FROM cinema.users u CROSS JOIN cinema.roles r
WHERE r.code='customer' AND u.email IN (
 'manager.demo@example.test','cashier.demo@example.test',
 'editor.demo@example.test','projection.demo@example.test')
ON CONFLICT DO NOTHING;
COMMIT;

-- Sample security checks (expected: true, false, true)
SELECT cinema.has_permission('55555555-5555-4555-8555-555555555505',
 'orders.sell_cinema','11111111-1111-4111-8111-111111111101') AS cashier_can_sell_own;
SELECT cinema.has_permission('55555555-5555-4555-8555-555555555505',
 'orders.sell_cinema','11111111-1111-4111-8111-111111111102') AS cashier_can_sell_other;
SELECT cinema.has_permission('55555555-5555-4555-8555-555555555503',
 'platform.manage') AS super_admin_can_manage;
