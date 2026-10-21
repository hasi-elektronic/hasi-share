import { requireSession } from "./auth/session";
import { requireFeature } from "./features";
import { HttpError, badRequest, json, readJsonObject, type Ctx } from "./http";

export const MAX_FAVORITES = 5000;
export const MAX_PROGRESS = 2000;
export const MAX_ITEMS_PER_REQUEST = 500;
export const MAX_PAGE = 500;
const MAX_DATA_BYTES = 4096;
const MAX_KEY_LENGTH = 300;
/** Client clocks may be skewed, but far-future timestamps would freeze LWW forever. */
const MAX_FUTURE_SKEW_MS = 86_400_000;
/** D1 allows at most 100 bound parameters per statement. */
const IN_CHUNK = 90;

type Kind = "favorite" | "progress";

interface Item {
  key: string;
  kind: Kind;
  data: Record<string, unknown>;
  updatedAt: number;
  deleted: boolean;
}

interface Rejected {
  key: string | null;
  reason: string;
}

function parseItem(raw: unknown, now: number): Item | Rejected {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { key: null, reason: "invalid_item" };
  const o = raw as Record<string, unknown>;
  const key = typeof o.key === "string" ? o.key : null;
  if (!key || key.length > MAX_KEY_LENGTH) return { key, reason: "invalid_key" };
  const kind = o.kind;
  if (kind !== "favorite" && kind !== "progress") return { key, reason: "invalid_kind" };
  if (!key.startsWith(kind === "favorite" ? "fav:" : "prog:") || key.length < (kind === "favorite" ? 5 : 6)) {
    return { key, reason: "invalid_key" };
  }
  const updatedAt = o.updatedAt;
  if (typeof updatedAt !== "number" || !Number.isSafeInteger(updatedAt) || updatedAt <= 0) {
    return { key, reason: "invalid_updated_at" };
  }
  if (updatedAt > now + MAX_FUTURE_SKEW_MS) return { key, reason: "updated_at_in_future" };
  const deleted = o.deleted === true;
  if (o.deleted !== undefined && typeof o.deleted !== "boolean") return { key, reason: "invalid_deleted" };
  let data: Record<string, unknown> = {};
  if (o.data !== undefined && o.data !== null) {
    if (typeof o.data !== "object" || Array.isArray(o.data)) return { key, reason: "invalid_data" };
    data = o.data as Record<string, unknown>;
  }
  if (new TextEncoder().encode(JSON.stringify(data)).byteLength > MAX_DATA_BYTES) return { key, reason: "data_too_large" };
  return { key, kind, data, updatedAt, deleted };
}

/** GET /v1/sync?since=<cursor>&limit=500 */
export async function syncGet(c: Ctx): Promise<Response> {
  await requireFeature(c, "sync");
  const s = await requireSession(c);
  const sinceRaw = c.url.searchParams.get("since") ?? "0";
  const limitRaw = c.url.searchParams.get("limit") ?? String(MAX_PAGE);
  const since = sinceRaw === "" ? 0 : Number(sinceRaw);
  const limit = Number(limitRaw);
  if (!Number.isSafeInteger(since) || since < 0) throw badRequest("'since' must be a non-negative integer cursor.");
  if (!Number.isInteger(limit) || limit < 1) throw badRequest("'limit' must be a positive integer.");
  const pageSize = Math.min(limit, MAX_PAGE);
  const { results } = await c.env.DB.prepare(
    "SELECT key, kind, data, updated_at, deleted, seq FROM sync_items WHERE account_id = ?1 AND seq > ?2 ORDER BY seq LIMIT ?3",
  )
    .bind(s.accountId, since, pageSize + 1)
    .all<{ key: string; kind: Kind; data: string; updated_at: number; deleted: number; seq: number }>();
  const hasMore = results.length > pageSize;
  const page = hasMore ? results.slice(0, pageSize) : results;
  const items = page.map((r) => ({
    key: r.key,
    kind: r.kind,
    data: safeParse(r.data),
    updatedAt: r.updated_at,
    deleted: r.deleted === 1,
    seq: r.seq,
  }));
  const cursor = page.length > 0 ? page[page.length - 1]!.seq : since;
  return json({ items, cursor, hasMore });
}

function safeParse(s: string): unknown {
  try {
    return JSON.parse(s);
  } catch {
    return {};
  }
}

/** POST /v1/sync {items: [SyncItem]} → {applied, cursor[, rejected]} */
export async function syncPost(c: Ctx): Promise<Response> {
  await requireFeature(c, "sync");
  const s = await requireSession(c);
  const body = await readJsonObject(c.req, 2 * 1024 * 1024);
  if (!Array.isArray(body.items)) throw badRequest("'items' must be an array.");
  if (body.items.length > MAX_ITEMS_PER_REQUEST) {
    throw new HttpError(413, "too_many_items", `At most ${MAX_ITEMS_PER_REQUEST} items per request.`);
  }
  const now = c.deps.now();
  const rejected: Rejected[] = [];
  // Last occurrence of a key within one request wins only if it is newer (same LWW rule).
  const byKey = new Map<string, Item>();
  for (const raw of body.items as unknown[]) {
    const it = parseItem(raw, now);
    if ("reason" in it) {
      rejected.push(it);
      continue;
    }
    const prev = byKey.get(it.key);
    if (!prev || it.updatedAt > prev.updatedAt) byKey.set(it.key, it);
  }
  const db = c.env.DB;
  const incoming = [...byKey.values()];

  // Load stored versions of the incoming keys to pre-filter LWW winners and enforce limits.
  const stored = new Map<string, { updated_at: number; deleted: number; kind: string }>();
  for (let i = 0; i < incoming.length; i += IN_CHUNK) {
    const chunk = incoming.slice(i, i + IN_CHUNK);
    const placeholders = chunk.map((_, j) => `?${j + 2}`).join(",");
    const { results } = await db
      .prepare(`SELECT key, updated_at, deleted, kind FROM sync_items WHERE account_id = ?1 AND key IN (${placeholders})`)
      .bind(s.accountId, ...chunk.map((x) => x.key))
      .all<{ key: string; updated_at: number; deleted: number; kind: string }>();
    for (const r of results) stored.set(r.key, r);
  }
  const winners = incoming.filter((it) => {
    const st = stored.get(it.key);
    return !st || it.updatedAt > st.updated_at; // ties keep stored (CONTRACT §8)
  });

  // Favorites limit: reject new live favorites beyond MAX_FAVORITES.
  const favCount =
    (
      await db
        .prepare("SELECT COUNT(*) AS n FROM sync_items WHERE account_id = ?1 AND kind = 'favorite' AND deleted = 0")
        .bind(s.accountId)
        .first<{ n: number }>()
    )?.n ?? 0;
  let liveFavs = favCount;
  for (const it of winners) {
    if (it.kind !== "favorite") continue;
    const st = stored.get(it.key);
    const wasLive = !!st && st.deleted === 0 && st.kind === "favorite";
    if (!it.deleted && !wasLive) liveFavs++;
    else if (it.deleted && wasLive) liveFavs--;
  }
  let toApply = winners;
  if (liveFavs > MAX_FAVORITES) {
    let excess = liveFavs - MAX_FAVORITES;
    const drop = new Set<string>();
    for (let i = winners.length - 1; i >= 0 && excess > 0; i--) {
      const it = winners[i]!;
      const st = stored.get(it.key);
      const wasLive = !!st && st.deleted === 0 && st.kind === "favorite";
      if (it.kind === "favorite" && !it.deleted && !wasLive) {
        drop.add(it.key);
        rejected.push({ key: it.key, reason: "favorites_limit" });
        excess--;
      }
    }
    toApply = winners.filter((it) => !drop.has(it.key));
  }

  let applied = 0;
  let cursor: number;
  if (toApply.length > 0) {
    // One transaction: each applied item gets seq = previous counter + position; the
    // counter is then advanced by the batch size (gaps are fine, order is monotonic).
    const stmts = toApply.map((it, i) =>
      db
        .prepare(
          "INSERT INTO sync_items (account_id, key, kind, data, updated_at, deleted, seq) " +
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, (SELECT sync_seq FROM accounts WHERE id = ?1) + ?7) " +
            "ON CONFLICT(account_id, key) DO UPDATE SET kind = excluded.kind, data = excluded.data, " +
            "updated_at = excluded.updated_at, deleted = excluded.deleted, seq = excluded.seq " +
            "WHERE excluded.updated_at > sync_items.updated_at",
        )
        .bind(s.accountId, it.key, it.kind, JSON.stringify(it.data), it.updatedAt, it.deleted ? 1 : 0, i + 1),
    );
    stmts.push(
      db.prepare("UPDATE accounts SET sync_seq = sync_seq + ?2 WHERE id = ?1").bind(s.accountId, toApply.length),
    );
    const results = await db.batch(stmts);
    for (let i = 0; i < toApply.length; i++) applied += (results[i]?.meta.changes ?? 0) > 0 ? 1 : 0;
  }

  // Progress limit: trim the oldest live progress items.
  const progCount =
    (
      await db
        .prepare("SELECT COUNT(*) AS n FROM sync_items WHERE account_id = ?1 AND kind = 'progress' AND deleted = 0")
        .bind(s.accountId)
        .first<{ n: number }>()
    )?.n ?? 0;
  if (progCount > MAX_PROGRESS) {
    await db
      .prepare(
        "DELETE FROM sync_items WHERE account_id = ?1 AND key IN (SELECT key FROM sync_items WHERE account_id = ?1 " +
          "AND kind = 'progress' AND deleted = 0 ORDER BY updated_at ASC, key ASC LIMIT ?2)",
      )
      .bind(s.accountId, progCount - MAX_PROGRESS)
      .run();
  }

  const acc = await db.prepare("SELECT sync_seq FROM accounts WHERE id = ?1").bind(s.accountId).first<{ sync_seq: number }>();
  cursor = acc?.sync_seq ?? 0;
  const out: Record<string, unknown> = { applied, cursor };
  if (rejected.length > 0) out.rejected = rejected;
  return json(out);
}
