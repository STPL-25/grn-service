import express from "express";
import cors from "cors";
import helmet from "helmet";
import compression from "compression";
import { configDotenv } from "dotenv";

import { initializeDatabase, closeDatabase } from "./src/config/db.js";
// Redis integration commented out — will be reintegrated later.
// import { createRedisClient } from "./src/config/redis.js";
import verifyJWT from "./src/middleware/auth.js";
import { apiLimiter } from "./src/middleware/rateLimiter.js";
import { notFoundHandler, errorHandler } from "./src/middleware/errorHandler.js";
import GRNRouter from "./src/grn/grn.routes.js";
import GateEntryRouter from "./src/gateentry/gateentry.routes.js";
import InventoryRouter from "./src/inventory/inventory.routes.js";
import StockRequestRouter from "./src/stockrequest/stockrequest.routes.js";
import SupplierRouter from "./src/supplier/supplier.routes.js";

configDotenv();

const PORT = parseInt(process.env.PORT || "8084");
const SERVICE_NAME = "grn-service";

// ----------------------------
// EXTERNAL CONNECTIONS
// ----------------------------
// Redis integration commented out — will be reintegrated later.
// const redisClient = createRedisClient();
// await redisClient.connect();
// console.log(`[${SERVICE_NAME}] Redis connected`);
const redisClient = null;

await initializeDatabase();
console.log(`[${SERVICE_NAME}] MSSQL pool ready`);

// ----------------------------
// APP
// ----------------------------
const app = express();
app.disable("x-powered-by");
app.set("trust proxy", 1); // behind API gateway / reverse proxy

app.use(helmet());
app.use(compression());
app.use(
  cors({
    origin: process.env.CLIENT_URL?.split(",") ?? "*",
    credentials: true,
  })
);
app.use(express.json({ limit: "5mb" }));
app.use(express.urlencoded({ extended: true }));

// Make the shared Redis client available to cache middleware + draft repo
app.use((req, _res, next) => {
  req.redisClient = redisClient;
  next();
});

// ----------------------------
// HEALTH (unauthenticated — for orchestrators / load balancers)
// ----------------------------
app.get("/grnhealth", (_req, res) => {
  res.json({ service: SERVICE_NAME, status: "up", timestamp: new Date().toISOString() });
});

app.get("/health/ready", async (_req, res) => {
  const checks = { mssql: false };
  try {
    const pool = await initializeDatabase();
    await pool.request().query("SELECT 1 AS ok");
    checks.mssql = true;
  } catch { /* stays false */ }
  // Redis check commented out — will be reintegrated later.
  // try {
  //   checks.redis = (await redisClient.ping()) === "PONG";
  // } catch { /* stays false */ }

  const ready = checks.mssql;
  res.status(ready ? 200 : 503).json({ service: SERVICE_NAME, ready, checks });
});

// ----------------------------
// ROUTES
// ----------------------------
app.use("/api/grn",  GRNRouter);
app.use("/api/gate_entry", verifyJWT, apiLimiter, GateEntryRouter);
app.use("/api/inventory", verifyJWT, apiLimiter, InventoryRouter);
app.use("/api/stock_request", verifyJWT, apiLimiter, StockRequestRouter);
// Auth is mixed per-route here (staff JWT for /invite, none for /login,
// supplier JWT for everything else) — see src/supplier/supplier.routes.js
app.use("/api/supplier", apiLimiter, SupplierRouter);

app.use(notFoundHandler);
app.use(errorHandler);

// ----------------------------
// START + GRACEFUL SHUTDOWN
// ----------------------------
const server = app.listen(PORT, () => {
  console.log(`[${SERVICE_NAME}] listening on port ${PORT}`);
});

async function shutdown(signal) {
  console.log(`[${SERVICE_NAME}] ${signal} received — shutting down`);
  server.close(async () => {
    try {
      // Redis integration commented out — will be reintegrated later.
      await Promise.allSettled([closeDatabase()]);
    } finally {
      process.exit(0);
    }
  });
  // Force-exit if connections refuse to drain
  setTimeout(() => process.exit(1), 10_000).unref();
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
