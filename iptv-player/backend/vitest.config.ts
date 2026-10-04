import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Tests run inside the real Workers runtime (workerd) with a local D1 database.
// Migrations from ./migrations are applied once per test file (see test/setup.ts).
export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            // Test-only overrides of [vars]; secrets are injected per test (test/helpers.ts).
            DEV_MODE: "true",
            PUBLIC_BASE_URL: "https://tv.example.test",
            LICENSE_KID: "test-1",
          },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/setup.ts"],
      include: ["test/**/*.test.ts"],
    },
  };
});
