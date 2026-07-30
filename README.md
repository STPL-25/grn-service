# GRN Microservice

Standalone microservice for the **goods-inward domain** — Gate Entry, GRN (Goods Receipt Note) against approved POs, and Inventory management — extracted from the Non-Trade ERP monolith (`backend/src/GRN`). Runs on port **8084** by default.

## Architecture

| Concern | Approach |
|---|---|
| Auth | Stateless `Authorization: Bearer <jwt>` (HS256, same `JWT_SECRET` as the monolith — tokens issued by the monolith's login flow verify here) |
| Database | Dedicated MSSQL pool (max 20) against the same `Non_Trade` DB, calling the same `sp_nt_*` stored procedures |
| Drafts & cache | Shared Redis instance, identical key namespace (`grn:draft:*`, `grn:drafts:*`, `grn:pending_pos`, `grn:by_po:*`, `grn:all`) — drafts and caches remain interchangeable with the monolith during migration |
| Resilience | `/health` (liveness) + `/health/ready` (MSSQL + Redis probes), graceful shutdown, rate limiting, helmet, compression |

```
grn-service/
├── index.js                    # bootstrap: connections, middleware, routes, shutdown
├── src/
│   ├── config/
│   │   ├── db.js               # MSSQL pool (lazy init + reconnect)
│   │   └── redis.js            # Redis client factory
│   ├── middleware/
│   │   ├── auth.js             # stateless Bearer JWT verification
│   │   ├── rateLimiter.js
│   │   ├── redisCache.js       # cacheMiddleware + invalidation helpers
│   │   └── errorHandler.js
│   ├── grn/
│   │   ├── grn.routes.js
│   │   ├── grn.controller.js
│   │   ├── grn.service.js
│   │   └── grn.repository.js   # sp_nt_* calls + Redis draft store
│   ├── gateentry/              # security inward register (before GRN)
│   │   └── gateentry.{routes,controller,service,repository}.js
│   └── inventory/              # item master + stock movement ledger
│       └── inventory.{routes,controller,service,repository}.js
```

## Endpoints

All under `/api/grn`, `/api/gate_entry`, `/api/inventory` — JWT-protected, rate-limited (200 req/min/IP).

### DB operations
| Method | Path | Notes |
|---|---|---|
| GET | `/api/grn/getPendingPOs` | cached 120 s (`grn:pending_pos`) |
| GET | `/api/grn/getGRNsByPO/:po_basic_sno` | cached 120 s (`grn:by_po:{sno}`) |
| POST | `/api/grn/createGRN` | invalidates GRN caches |
| GET | `/api/grn/getAllGRNs` | cached 120 s (`grn:all`) |

### Draft operations (Redis, per-user, 30-day TTL)
| Method | Path |
|---|---|
| POST | `/api/grn/saveGRNDraft` |
| GET | `/api/grn/getGRNDrafts` |
| GET | `/api/grn/getGRNDraft/:draftId` |
| PUT | `/api/grn/updateGRNDraft/:draftId` |
| DELETE | `/api/grn/deleteGRNDraft/:draftId` |
| POST | `/api/grn/submitGRNDraft/:draftId` |

### Gate Entry (security inward register, before GRN)
| Method | Path | Notes |
|---|---|---|
| GET | `/api/gate_entry/getApprovedPOs` | approved POs pending receipt — cached 120 s (`gate:approved_pos`) |
| GET | `/api/gate_entry/getAllGateEntries` | optional `?status=` filter — cached 120 s (`gate:all`) |
| GET | `/api/gate_entry/getGateEntriesByPO/:po_basic_sno` | cached 120 s (`gate:by_po:{sno}`) |
| POST | `/api/gate_entry/createGateEntry` | generates `GE/YYYY/NNNNNN`, invalidates gate caches |
| PUT | `/api/gate_entry/updateGateEntryStatus/:gate_entry_sno` | body `{ status }` ∈ In / Verified / GRN Done / Out |

### Inventory (item master + stock ledger)
| Method | Path | Notes |
|---|---|---|
| GET | `/api/inventory/getItems` | optional `?category=&warehouse=&status=` — cached 120 s (`inv:items`) |
| POST | `/api/inventory/createItem` | opening stock is logged as an `IN` movement |
| PUT | `/api/inventory/updateItem/:item_sno` | master data only — stock changes go through adjustStock |
| DELETE | `/api/inventory/deleteItem/:item_sno` | soft delete → status `Discontinued` |
| GET | `/api/inventory/getMovements/:item_sno` | cached 120 s (`inv:movements:{sno}`) |
| POST | `/api/inventory/adjustStock` | `{ item_sno, movement_type: IN\|OUT\|ADJUSTMENT\|TRANSFER, quantity, to_warehouse?, reference_no?, reason? }` |

### Health
| Method | Path | Auth |
|---|---|---|
| GET | `/health` | none — liveness |
| GET | `/health/ready` | none — readiness (checks MSSQL + Redis) |

## Run

```bash
cd grn-service
npm install
cp .env.example .env   # adjust if needed
npm run dev            # or: npm start
```

Docker:

```bash
docker build -t grn-service .
docker run -p 8084:8084 --env-file .env grn-service
```

## Testing without the frontend

With `NODE_ENV !== production` and `DEV_BYPASS_TOKEN` set:

```bash
curl -H "Authorization: Bearer dev-postman-2026" http://localhost:8084/api/grn/getAllGRNs
```

## Routing traffic to this service

The React frontend authenticates with the monolith via an HttpOnly **session cookie**; this service is stateless and expects a **Bearer JWT**. Two integration options:

1. **API gateway (recommended long-term)** — nginx / Kong / Express gateway terminates the session, looks up `req.session.jwt`, and forwards `Authorization: Bearer <jwt>` to `grn-service` for `/api/grn/*`.
2. **Monolith as proxy (quick migration)** — replace the GRN router mount in `backend/index.js` with a thin proxy that forwards the request plus `Authorization: Bearer ${req.session.jwt}` to `http://localhost:8084`. Zero frontend changes; Redis draft/cache keys are already shared, so behavior is identical.

The mobile/Flutter backends already use Bearer JWTs, so they can call this service directly.

The React frontend has a typed client layer for all three domains in `frontend/src/Services/GrnService/` (`gateEntryApi.ts`, `grnApi.ts`, `inventoryApi.ts`). It targets `VITE_GRN_SERVICE_URL` when set (gateway in front of this service), otherwise `VITE_API_URL` (monolith/proxy).

## Database setup

Run the scripts in `sql/` in order against the `Non_Trade` DB:

| Script | Creates |
|---|---|
| `01_grn.sql` | `nt_grn_basic_info`, `nt_grn_item_details` + original `sp_nt_*` GRN procs — **superseded, see `07_grn_procs_v2.sql`** |
| `02_inventory.sql` | `nt_inventory_items`, `nt_stock_movements` + `sp_nt_GetInventoryItems`, `sp_nt_CreateInventoryItem`, `sp_nt_UpdateInventoryItem`, `sp_nt_DeleteInventoryItem`, `sp_nt_GetStockMovements`, `sp_nt_AdjustStock` |
| `03_gateentry.sql` | `nt_gate_entry` + `sp_nt_CreateGateEntry`, `sp_nt_GetAllGateEntries`, `sp_nt_GetGateEntriesByPO`, `sp_nt_UpdateGateEntryStatus` |
| `05_grn_basic_info_v2.sql`, `05_grn_item_details.sql`, `06_grn_history_data.sql` | `grn_basic_info`, `grn_item_details`, `grn_history_data` — the tables the GRN procs run against as of 2026-07-20 |
| `07_grn_procs_v2.sql` | Repoints `sp_nt_CreateGRN`/`sp_nt_GetAllGRNs`/`sp_nt_GetGRNsByPO`/`sp_nt_GetPendingGateEntriesForGRN` at `grn_basic_info`/`grn_item_details`, adds `grn_history_data` audit logging on create. Run after the three scripts above. `nt_grn_basic_info`/`nt_grn_item_details` are no longer written to. |
