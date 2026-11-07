# Sphera 3D — Киностар, Грозный Молл

Концепт для хакатона: афиша, 8 залов в 3D, вид и звук с любого кресла, бронирование и тестовая оплата.
Не официальный сайт Киностар: залы смоделированы приблизительно, фильмы и цены вымышленные, оплата учебная.

- Сайт: https://sphera-3d-grozny.vercel.app
- API: `https://sphera-3d-grozny.vercel.app/api/...` (Vercel проксирует на Supabase Edge Function `api`)
- База: Supabase, проект `xyjgngqsofhrsmovuqoz`

## Что внутри

```
index.html            оболочка: шапка, навигация, кнопка звука, canvas для 3D
vite.config.js        сборка; локально /api проксируется на http://localhost:8000
vercel.json           /api/* → Supabase Edge Function, остальное → index.html (SPA)
src/
  main.js             роутер (history API) и шапка
  lib.js              запросы к API, форматирование дат/цен, постеры, «мои заказы» в localStorage
  pages/catalog.js    главная (афиша: даты, фильтр стандарт/VIP) и страница фильма
  pages/halls.js      список залов 1–8, разделён на стандартные и VIP
  pages/scene.js      3D-страницы: зал (осмотр и проверка звука) и сеанс (выбор мест, бронь)
  pages/orders.js     оплата брони с таймером, тестовый шлюз Sandbox Pay, билеты с QR, «Мои билеты»
  scene/stage.js      сцена three.js: камера, пересадка в кресло, подсветка, bloom
  scene/hall.js       генератор зала по данным из БД (ряды, кресла, экран, колонки)
  audio/engine.js     Web Audio: музыка сайта, звук зала через колонки, проверка звука с места, оценка акустики
  ornament.js, film.js  орнамент и «фильм» на экране (шейдер)
  style.css, app.css  стили
supabase/
  migrations/         SQL по порядку номеров
  functions/api/      Edge Function (Deno) — HTTP API
  tests/              api_flow_test.sql (SQL), http_flow_test.mjs (HTTP)
```

## Маршруты сайта

| Путь | Страница |
|---|---|
| `/` | Афиша: даты на неделю, фильтр «Все / Стандартные / VIP» |
| `/movie/:id` | Фильм и его сеансы по типам залов |
| `/halls` | Все 8 залов: стандартные 1–5, VIP 6–8 |
| `/hall/:id` | Зал в 3D: сесть в любое кресло, проверить звук |
| `/session/:id` | Сеанс: выбор до 8 мест, вид и звук с места, бронь |
| `/checkout/:id` | Бронь на 10 минут, оплата или отмена |
| `/pay/:id` | Тестовый платёжный шлюз Sandbox Pay |
| `/order/:id` | Оплаченные билеты с QR-кодами |
| `/tickets` | Мои билеты (заказы этого браузера) |

## HTTP API (`supabase/functions/api/index.ts`)

```
GET  /health
GET  /catalog                         фильмы + сеансы на 7 дней
GET  /movies/:id
GET  /halls                           залы с планом, ценой «от», ближайшими сеансами
GET  /halls/:id                       зал, кресла, колонки, сеансы
GET  /screenings/:id                  сеанс, кресла с ценами и статусами
GET  /screenings/:id/availability     занятые места (опрос раз в 12 с)
POST /orders                          {screening_id, seat_ids[], email, idempotency_key} → {order_id, token, expires_at, total}
GET  /orders/:id?token=
POST /orders/:id/cancel               {token}
POST /orders/:id/payment              {token} → {session_id}
GET  /sandbox/:id                     сессия тестового шлюза
POST /sandbox/:id/complete            {outcome: success|decline}
POST /webhooks/sandbox-pay            заголовок x-sandbox-signature (HMAC), тело — уведомление шлюза
```

Ошибки: 400 (неверные данные), 403 (неверный токен заказа), 404, 409 (место заняли / бронь истекла).

## Как устроены бронь и оплата

1. `book_seats` держит места 10 минут (`hold_seats`), создаёт заказ `pending` и возвращает токен заказа — HMAC от id. Секрет лежит в `cinema_private.app_secrets` и наружу не выходит.
2. `create_payment_session` открывает сессию шлюза.
3. Шлюз (`sandbox_complete`) подписывает уведомление и передаёт его в `handle_payment_webhook`. Там SQL проверяет подпись и сумму, затем вызывает `confirm_payment`, и появляются билеты.
4. Если оплата пришла после истечения брони, платёж помечается `failed_late`, билеты не выдаются.
5. pg_cron: `expire_pending_orders` каждую минуту, `ensure_schedule(7)` каждый день в 00:10 UTC (дополняет расписание на неделю вперёд).

Edge Function подключается к БД и для каждого запроса делает `SET LOCAL ROLE` в нужную ограниченную роль:
`cinema_reader`, `cinema_booking`, `cinema_webhook` или `cinema_sandbox_provider`. Все изменения идут только через SECURITY DEFINER-функции.

## Миграции — порядок

```
001_schema  003_booking_triggers  005_seed_data  006_rbac  007_rbac_seed
008_hardening  009_sql_roles  012_acoustic_seed  013_app_api  014_kinostar_seed
015_cron_jobs  016_move_btree_gist
```
- `004_demo.sql` не применялась (демо-сценарий из исходного набора).
- `011_hardening_checks.sql` — это тест. Запускать в транзакции с ROLLBACK.
- `013` содержит исправление исходного 008/009: отложенный триггер `consistency_event` срабатывал при COMMIT от имени роли приложения, у которой нет права EXECUTE на `assert_order_consistency`. Функция стала SECURITY DEFINER.

## Запуск локально

Нужны Node 18+, PostgreSQL 15+ (с расширениями `pgcrypto`, `btree_gist`) и Deno.

```bash
# 1. База
createdb kino
for f in 001_schema 003_booking_triggers 005_seed_data 006_rbac 007_rbac_seed 008_hardening \
         009_sql_roles 012_acoustic_seed 013_app_api 014_kinostar_seed; do
  psql kino -v ON_ERROR_STOP=1 -f supabase/migrations/$f.sql
done
# 015 (pg_cron) и 016 нужны только на Supabase; локально можно пропустить
psql kino -c "select cinema.ensure_schedule(7)"

# 2. API на :8000
SUPABASE_DB_URL=postgres://user:pass@localhost:5432/kino \
  deno run --allow-net --allow-env --node-modules-dir=none supabase/functions/api/index.ts

# 3. Сайт на :5173
npm install
npm run dev

# Тесты
psql kino -f supabase/tests/api_flow_test.sql
node supabase/tests/http_flow_test.mjs http://localhost:8000/api
```

## Деплой

- **Supabase:** применить миграции по порядку (SQL Editor или `supabase db push`). Затем `supabase functions deploy api --no-verify-jwt`; функция использует встроенную переменную `SUPABASE_DB_URL`.
- **Vercel:** импортировать папку как проект Vite (Build `vite build`, Output `dist`). Если у вас другой проект Supabase, поменяйте адрес в `vercel.json`.

## Что поменять для настоящего запуска

- Заменить Sandbox Pay на реального эквайера (ЮKassa, CloudPayments и т. п.). Логика проверки подписи в `handle_payment_webhook` остаётся та же.
- Отправлять билеты на e-mail.
- Сменить секреты в `cinema_private.app_secrets`.
- Подставить реальные схемы залов и расписание из билетной системы кинотеатра.
