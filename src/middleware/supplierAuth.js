import jwt from "jsonwebtoken";
import { configDotenv } from "dotenv";
configDotenv();

const JWT_SECRET = process.env.JWT_SECRET;
const SUPPLIER_TOKEN_TYPE = "supplier";
const SUPPLIER_TOKEN_EXPIRY = "12h";

const DEV_BYPASS_TOKEN = process.env.SUPPLIER_DEV_BYPASS_TOKEN;
const DEV_BYPASS_SUPPLIER = { kyc_basic_info_sno: 0, supp_code: "DEVSUPP", email: "dev@example.com" };

function getBearerToken(req) {
  const authorization = req.headers?.authorization ?? req.headers?.Authorization;
  if (typeof authorization !== "string") return null;

  const [scheme, token] = authorization.trim().split(/\s+/);
  if (scheme?.toLowerCase() !== "bearer" || !token) return null;

  return token;
}

/**
 * Signs a stateless JWT for a supplier principal. Uses the same JWT_SECRET
 * as the monolith/grn-service staff tokens, but `type: "supplier"` keeps
 * the two token spaces from being interchangeable — verifySupplierAuth
 * rejects a staff token and verifyJWT (src/middleware/auth.js) never looks
 * for a `type` claim, so a supplier token has no `ecno` and is useless there.
 */
function signSupplierToken(supplier) {
  return jwt.sign({ supplier, type: SUPPLIER_TOKEN_TYPE }, JWT_SECRET, {
    algorithm: "HS256",
    expiresIn: SUPPLIER_TOKEN_EXPIRY,
  });
}

const verifySupplierAuth = (req, res, next) => {
  const token = getBearerToken(req);
  if (process.env.NODE_ENV !== "production" && DEV_BYPASS_TOKEN && token === DEV_BYPASS_TOKEN) {
    req.supplier = DEV_BYPASS_SUPPLIER;
    return next();
  }

  if (!token) {
    return res.status(401).json({ success: false, message: "Access denied. Please log in." });
  }

  try {
    const payload = jwt.verify(token, JWT_SECRET, { algorithms: ["HS256"] });

       console.log("Decoded JWT payload:", payload); // Debugging line
    if (payload.type !== SUPPLIER_TOKEN_TYPE || !payload.supplier) {
      return res.status(401).json({ success: false, message: "Invalid session." });
    }
    req.supplier = payload.supplier;
    next();
  } catch (error) {
    console.error("JWT verification error:", error); // Debugging line
    if (error.name === "TokenExpiredError") {
      return res.status(401).json({ success: false, message: "Session expired. Please log in again." });
    }
    return res.status(401).json({ success: false, message: "Invalid session." });
  }
};

export { signSupplierToken, verifySupplierAuth };
export default verifySupplierAuth;
