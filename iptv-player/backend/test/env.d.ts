// Types `env` from "cloudflare:workers" / "cloudflare:test" in tests.
type ProjectEnv = import("../src/env").Env;
type ProjectMigrations = import("cloudflare:test").D1Migration[];

declare namespace Cloudflare {
  interface Env extends ProjectEnv {
    TEST_MIGRATIONS: ProjectMigrations;
  }
}
