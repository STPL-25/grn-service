// grn-service test setup — mirrors backend-stpl/tests/setup.js's shape so
// both services' test suites read the same way.
import { jest } from "@jest/globals";

/** Build a minimal Express-like mock request */
export function mockReq(overrides = {}) {
  return {
    user:        { ecno: "TEST001", ename: "Test User" },
    redisClient: null,
    body:        {},
    params:      {},
    query:       {},
    headers:     {},
    ...overrides,
  };
}

/** Build a minimal mock response with jest spy methods */
export function mockRes() {
  const res = {};
  res.statusCode = 200;
  res.status = jest.fn().mockImplementation((code) => { res.statusCode = code; return res; });
  res.json  = jest.fn().mockReturnValue(res);
  res.send  = jest.fn().mockReturnValue(res);
  return res;
}
