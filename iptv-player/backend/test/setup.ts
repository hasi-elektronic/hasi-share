import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

// Runs once per test file (inside workerd) – creates the schema from ./migrations.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
