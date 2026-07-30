/**
 * Bridges grn-service (stateless, no Socket.IO) to the monolith's Socket.IO
 * server: publish a JSON message on the shared Redis channel
 * "socket:broadcast" and backend/index.js (which owns the only `io`
 * instance) subscribes to that channel and re-emits it to the target room.
 */
export function broadcast(redisClient, room, event, payload) {
  if (!redisClient || !room || !event) return;
  redisClient
    .publish("socket:broadcast", JSON.stringify({ room, event, payload }))
    .catch((err) => console.error("[grn-service] socket broadcast failed:", err.message));
}
