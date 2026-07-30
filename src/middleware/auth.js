import jwt from "jsonwebtoken";
import { configDotenv } from "dotenv";
configDotenv();

const JWT_SECRET = process.env.JWT_SECRET;

// Dev bypass: only active when NODE_ENV !== 'production' AND DEV_BYPASS_TOKEN is set
const DEV_BYPASS_TOKEN = process.env.DEV_BYPASS_TOKEN;
const DEV_BYPASS_ECNO = process.env.DEV_BYPASS_ECNO || "DEV001";

function getBearerToken(req) {
  const authorization = req.headers?.authorization ?? req.headers?.Authorization;
  if (typeof authorization !== "string") return null;

  const [scheme, token] = authorization.trim().split(/\s+/);
  if (scheme?.toLowerCase() !== "bearer" || !token) return null;

  return token;
}

function getUserFromPayload(payload) {
  return payload.user ?? payload;
}

function getEcnoFromUser(user) {
  const normalizedUser = Array.isArray(user) ? user[0] : user;
  return normalizedUser?.ecno ?? null;
}

/**
 * Stateless JWT verification for the GRN microservice.
 *
 * Unlike the monolith (which reads the JWT from a server-side session),
 * a microservice must not depend on the monolith's session store. The
 * caller — API gateway or the monolith acting as proxy — forwards the
 * JWT as `Authorization: Bearer <jwt>`. Tokens are signed with the same
 * JWT_SECRET, so tokens issued by the monolith's login flow verify here.
 */
const verifyJWT = (req, res, next) => {
  const token = getBearerToken(req);

  // Dev bypass for Postman/API docs — never active in production
  if (process.env.NODE_ENV !== "production" && DEV_BYPASS_TOKEN && token === DEV_BYPASS_TOKEN) {
    req.user = { ecno: DEV_BYPASS_ECNO, name: "Dev User", role: "dev" };
    req.user_ecno = DEV_BYPASS_ECNO;
    return next();
  }

  if (!token) {
    return res.status(401).json({ success: false, message: "Access denied. Please log in." });
  }

  try {
    const payload = jwt.verify(token, JWT_SECRET, { algorithms: ["HS256"] });
    req.user = getUserFromPayload(payload);
    req.user_ecno = getEcnoFromUser(req.user);
    next();
  } catch (error) {
    if (error.name === "TokenExpiredError") {
      return res.status(401).json({ success: false, message: "Session expired. Please log in again." });
    }
    return res.status(401).json({ success: false, message: "Invalid session." });
  }
};

export default verifyJWT;
