import rateLimit from "express-rate-limit";

/**
 * General API limiter — 200 requests per IP per minute,
 * matching the monolith's apiLimiter.
 */
export const apiLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 200,
  standardHeaders: true,
  legacyHeaders: false,
  message: {
    success: false,
    message: "Too many requests. Please slow down.",
  },
});
