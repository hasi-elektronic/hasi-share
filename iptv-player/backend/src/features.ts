import { getConfig, type AppConfig } from "./config";
import { HttpError, type Ctx } from "./http";

/** Rejects requests to optional features that an admin switched off. */
export async function requireFeature(c: Ctx, feature: keyof AppConfig["features"]): Promise<void> {
  const cfg = await getConfig(c.env);
  if (!cfg.features[feature]) {
    throw new HttpError(403, "feature_disabled", `The '${feature}' feature is disabled.`);
  }
}
