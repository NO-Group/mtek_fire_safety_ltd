# M-TEK Data API — MongoDB storage (Supabase is AUTH only)

One Atlas cluster, SEVEN section databases (owner directive: never entangled):

| Database         | Section                          | Collections |
|------------------|----------------------------------|-------------|
| `mtek_core`      | serials · settings               | serials, settings |
| `mtek_inventory` | products · stock edits           | products, stock_adjustments |
| `mtek_people`    | customers · staff role map       | customers, profiles |
| `mtek_billing`   | money                            | sales, transactions, invoices, receipts, invoice_payments |
| `mtek_mils`      | MILS service logs                | logs |
| `mtek_documents` | issued-document archive          | archive |
| `mtek_audit`     | audit-trail events               | events |

**Serial books start at 000000001** (9 digits) — atomic `findOneAndUpdate`
counters, CEO-reseedable.

## Run
```
cd backend/api && npm install && npm start        # :8090
```
All config comes from `backend/.env` (gitignored): `MONGODB_URI`,
`SUPABASE_URL`, `SUPABASE_SECRET_KEY`, `MTEK_CEO_UID`, `MTEK_CEO_SIG`.

## Auth
Every route except `GET /health` needs `Authorization: Bearer <supabase-jwt>`
(validated against Supabase Auth). Roles live in `mtek_people.profiles`:
CEO hardcoded to `MTEK_CEO_UID` (never self-promotable), everyone else starts
as `sales`. Signature passcodes are stored as salted scrypt hashes.

## Authority matrix (server-enforced)
| Action | CEO | Admin | Sales |
|---|---|---|---|
| Sell / customers / payments | ✓ | ✓ | ✓ |
| Stock edits, product import, MILS | ✓ | ✓ | — |
| Freehand documents (generator) | ✓ | ✓ | — |
| Settings · serial reseed · reset | ✓ | — | — |

## Endpoints
`GET /health` · `GET /api/me` · `GET /api/bootstrap` · `POST /api/auth/signature`
· `POST /api/customers` · `POST /api/products/upsert` · `POST /api/stock/adjust`
· `POST /api/sales` · `POST /api/invoices/pay` · `POST /api/settings`
· `POST /api/docs/issue` · `GET /api/docs/history` · `GET|POST /api/mils`
· `GET /api/audit`

## One-time setup (any machine with normal internet)
```
node backend/scripts/seed-mongo.js     # creates DBs, zeroes serials, seeds CEO + catalogue
node backend/scripts/verify-live.js    # full live verification (Supabase + Mongo)
```
