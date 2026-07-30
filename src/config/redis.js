import { createClient } from "redis";
import { configDotenv } from "dotenv";
configDotenv();

/**
 * Shared Redis instance with the monolith — key namespaces (`grn:*`)
 * are identical so drafts and caches remain visible to both services
 * during migration.
 */
export function createRedisClient() {
  const client = createClient({
    socket: {
      host: process.env.REDIS_HOST || "localhost",
      port: parseInt(process.env.REDIS_PORT || "6379"),
      reconnectStrategy: (retries) => {
        if (retries > 10) return new Error("Redis connection failed after 10 retries");
        return Math.min(retries * 50, 500);
      },
    },
    password: process.env.REDIS_PASSWORD || undefined,
  });

  client.on("error", (err) => console.error("[grn-service] Redis error:", err.message));
  return client;
}
