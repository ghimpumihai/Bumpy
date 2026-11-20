/** Fails on runtime import cycles (frontend rule: "No runtime import cycles"). */
module.exports = {
  forbidden: [
    {
      name: "no-circular",
      severity: "error",
      comment: "Two modules must not import each other (directly or indirectly) unless only types are involved.",
      from: {},
      to: { circular: true, dependencyTypesNot: ["type-only"] },
    },
    {
      name: "no-mock-in-production-code",
      severity: "error",
      comment: "Only the API client may load the mock backend (lazily), so API users never download it.",
      from: { pathNot: ["^src/mock/", "^src/config/api-client\\.ts$", "/__tests__/"] },
      to: { path: "^src/mock/" },
    },
  ],
  options: {
    doNotFollow: { path: "node_modules" },
    tsConfig: { fileName: "tsconfig.app.json" },
    tsPreCompilationDeps: true,
    exclude: { path: "routeTree\\.gen\\.ts$" },
  },
};
