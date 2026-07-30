import sql from "mssql";
import { configDotenv } from "dotenv";
configDotenv();

const config = {
  user: process.env.DB_USER,
  password: process.env.DB_USER_PASSWORD,
  server: process.env.SERVER,
  database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433,
  options: {
    trustServerCertificate: true,
    enableArithAbort: true,
    connectionTimeout: 30000,
    requestTimeout: 30000,
  },
  pool: {
    // Dedicated pool for this service — sized below the monolith's 50
    max: parseInt(process.env.DB_POOL_MAX) || 20,
    min: parseInt(process.env.DB_POOL_MIN) || 2,
    idleTimeoutMillis: 30000,
    acquireTimeoutMillis: 15000,
  },
};

let pool;

async function initializeDatabase() {
  if (pool?.connected) return pool;
  try {
    pool = await sql.connect(config);
    return pool;
  } catch (err) {
    console.error("[grn-service] SQL Server connection failed:", err.message);
    throw err;
  }
}

async function closeDatabase() {
  if (pool) {
    await pool.close();
    pool = undefined;
  }
}

export { initializeDatabase, closeDatabase };
