// Mirrors backend-stpl/jest.config.js — same ESM/no-transform setup since
// this service also has "type":"module" in package.json.
export default {
  testEnvironment: "node",
  transform: {},
  testMatch: ["**/tests/**/*.test.js"],
  coverageDirectory: "coverage",
  collectCoverageFrom: [
    "src/**/*.js",
  ],
  testTimeout: 15000,
};
