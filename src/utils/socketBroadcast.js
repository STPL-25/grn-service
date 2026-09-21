/**
 * Bridges grn-service (stateless, no Socket.IO of its own) to the monolith's
 * Socket.IO server: POST { room, event, payload } to the monolith's internal
 * /internal/broadcast route, which re-emits it to the target room via its
 * `io` instance.
 *
 * Previously this went through Redis pub/sub (grn-service publishes on
 * "socket:broadcast", backend/index.js subscribes and re-emits). That path
 * is disabled in both services (no Redis client wired up), which silently
 * dropped every real-time inventory/GRN/stock-request event — this HTTP
 * call replaces it without requiring Redis.
 */
const BACKEND_PUBLIC_URL = process.env.BACKEND_PUBLIC_URL || "http://localhost:8081";
const INTERNAL_BROADCAST_SECRET = process.env.INTERNAL_BROADCAST_SECRET;

// `room` accepts either a single room name (string, unchanged) or an array
// of room names (e.g. from hierarchyScope.js's orgRoomTargets) — Socket.IO's
// io.to() natively accepts both and dedupes delivery across them.
export function broadcast(room, event, payload) {
  const rooms = Array.isArray(room) ? room.filter(Boolean) : room;
  const hasRoom = Array.isArray(rooms) ? rooms.length > 0 : Boolean(rooms);
  if (!hasRoom || !event) return;
  if (!INTERNAL_BROADCAST_SECRET) {
    console.error("[grn-service] INTERNAL_BROADCAST_SECRET is not set — dropping broadcast", { room, event });
    return;
  }

  fetch(`${BACKEND_PUBLIC_URL}/internal/broadcast`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-internal-secret": INTERNAL_BROADCAST_SECRET,
    },
    body: JSON.stringify({ room: rooms, event, payload }),
    signal: AbortSignal.timeout(3000),
  }).catch((err) => console.error("[grn-service] socket broadcast failed:", err.message));
}
