import { beforeEach, describe, expect, it } from "vitest";
import { DAY, Harness, T0, resetDb } from "./helpers";

let h: Harness;
let token: string;
beforeEach(async () => {
  await resetDb();
  h = await Harness.create();
  token = (await h.login("sync@example.com")).token;
});

const fav = (id: string, updatedAt: number, extra: Record<string, unknown> = {}) => ({
  key: `fav:0123456789abcdef:live:${id}`,
  kind: "favorite",
  data: { title: `Channel ${id}`, contentKind: "live", posterUrl: null },
  updatedAt,
  deleted: false,
  ...extra,
});
const prog = (id: string, updatedAt: number, positionMs = 1000) => ({
  key: `prog:0123456789abcdef:movie:${id}`,
  kind: "progress",
  data: { title: `Movie ${id}`, contentKind: "movie", positionMs, durationMs: 100_000 },
  updatedAt,
  deleted: false,
});

const push = (items: unknown[], t = token) => h.post("/v1/sync", { items }, { token: t });
const pull = (since = 0, limit?: number, t = token) =>
  h.get(`/v1/sync?since=${since}${limit !== undefined ? `&limit=${limit}` : ""}`, { token: t });

async function pullAll(t = token) {
  const out: Record<string, any>[] = [];
  let since = 0;
  for (;;) {
    const r = await pull(since, 500, t);
    out.push(...r.json.items);
    since = r.json.cursor;
    if (!r.json.hasMore) return { items: out, cursor: since };
  }
}

describe("sync – auth & validation", () => {
  it("401 without session (GET and POST)", async () => {
    expect((await h.get("/v1/sync")).status).toBe(401);
    expect((await h.post("/v1/sync", { items: [] })).status).toBe(401);
  });

  it("403 when the sync feature is disabled", async () => {
    await h.admin("PUT", "/v1/admin/config", { features: { sync: false } });
    expect((await pull()).status).toBe(403);
    expect((await push([])).json.error).toBe("feature_disabled");
  });

  it("400 for invalid cursor / limit / items", async () => {
    expect((await h.get("/v1/sync?since=-1", { token })).status).toBe(400);
    expect((await h.get("/v1/sync?since=abc", { token })).status).toBe(400);
    expect((await h.get("/v1/sync?limit=0", { token })).status).toBe(400);
    expect((await h.post("/v1/sync", { items: "x" }, { token })).status).toBe(400);
    expect((await h.post("/v1/sync", {}, { token })).status).toBe(400);
  });

  it("413 for more than 500 items per request", async () => {
    const items = Array.from({ length: 501 }, (_, i) => fav(String(i), T0));
    const r = await push(items);
    expect(r.status).toBe(413);
    expect(r.json.error).toBe("too_many_items");
  });

  it("rejects malformed items individually", async () => {
    const r = await push([
      fav("ok", T0),
      { ...fav("a", T0), kind: "bookmark" },
      { ...fav("b", T0), key: "prog:x" }, // key prefix does not match kind
      { ...fav("c", T0), updatedAt: "yesterday" },
      { ...fav("d", T0), updatedAt: T0 + 2 * DAY }, // far future
      { ...fav("e", T0), deleted: "no" },
      { ...fav("f", T0), data: [1] },
      { ...fav("g", T0), data: { blob: "x".repeat(5000) } },
      { ...fav("h", T0), key: "fav:" },
      42,
    ]);
    expect(r.status).toBe(200);
    expect(r.json.applied).toBe(1);
    expect(r.json.rejected.map((x: { reason: string }) => x.reason)).toEqual([
      "invalid_kind",
      "invalid_key",
      "invalid_updated_at",
      "updated_at_in_future",
      "invalid_deleted",
      "invalid_data",
      "data_too_large",
      "invalid_key",
      "invalid_item",
    ]);
  });
});

describe("sync – last-writer-wins (CONTRACT §8)", () => {
  it("round trip: items come back with seq, cursor and hasMore=false", async () => {
    const r = await push([fav("1", T0 - 10), prog("2", T0 - 5, 4000)]);
    expect(r.status).toBe(200);
    expect(r.json).toEqual({ applied: 2, cursor: 2 });
    const g = await pull();
    expect(g.json.hasMore).toBe(false);
    expect(g.json.cursor).toBe(2);
    expect(g.json.items).toEqual([
      { ...fav("1", T0 - 10), seq: 1 },
      { ...prog("2", T0 - 5, 4000), seq: 2 },
    ]);
    // nothing new since the cursor
    expect((await pull(2)).json).toEqual({ items: [], cursor: 2, hasMore: false });
  });

  it("newer updatedAt wins, older is ignored, ties keep the stored value", async () => {
    await push([prog("1", T0, 1000)]);
    expect((await push([prog("1", T0 - 1, 2000)])).json.applied).toBe(0); // older
    const tie = await push([{ ...prog("1", T0, 3000) }]);
    expect(tie.json.applied).toBe(0); // tie
    expect((await pullAll()).items[0]!.data.positionMs).toBe(1000);
    const newer = await push([prog("1", T0 + 1, 4000)]);
    expect(newer.json.applied).toBe(1);
    const all = await pullAll();
    expect(all.items).toHaveLength(1);
    expect(all.items[0]).toMatchObject({ updatedAt: T0 + 1, data: { positionMs: 4000 } });
  });

  it("within one request the newest duplicate wins", async () => {
    const r = await push([prog("1", T0 + 5, 5), prog("1", T0 + 9, 9), prog("1", T0 + 7, 7)]);
    expect(r.json.applied).toBe(1);
    expect((await pullAll()).items[0]!.data.positionMs).toBe(9);
  });

  it("tombstones: deletes propagate via the cursor, older writes cannot resurrect, newer can", async () => {
    await push([fav("1", T0)]);
    const c1 = (await pull()).json.cursor as number;
    expect((await push([fav("1", T0 + 10, { deleted: true, data: {} })])).json.applied).toBe(1);
    const d = await pull(c1);
    expect(d.json.items).toHaveLength(1);
    expect(d.json.items[0]).toMatchObject({ key: fav("1", 0).key, deleted: true, updatedAt: T0 + 10 });
    expect(d.json.items[0].seq).toBeGreaterThan(c1);

    expect((await push([fav("1", T0 + 5)])).json.applied).toBe(0); // stale device re-adds
    expect((await pullAll()).items[0]!.deleted).toBe(true);
    expect((await push([fav("1", T0 + 20)])).json.applied).toBe(1); // genuinely re-added later
    expect((await pullAll()).items[0]!.deleted).toBe(false);
  });

  it("updated items move behind the cursor (seq increases monotonically)", async () => {
    await push([fav("a", T0), fav("b", T0), fav("c", T0)]);
    const c = (await pull()).json.cursor as number;
    await push([fav("a", T0 + 1)]);
    const g = await pull(c);
    expect(g.json.items.map((i: { key: string }) => i.key)).toEqual([fav("a", 0).key]);
    const seqs = (await pullAll()).items.map((i) => i.seq as number);
    expect([...seqs].sort((x, y) => x - y)).toEqual(seqs);
    expect(new Set(seqs).size).toBe(seqs.length);
  });

  it("accounts are isolated", async () => {
    await push([fav("1", T0)]);
    const other = await h.login("other-sync@example.com");
    expect((await pull(0, 500, other.token)).json.items).toEqual([]);
    await push([fav("1", T0 - 100)], other.token); // same key, other account: independent
    expect((await pull(0, 500, other.token)).json.items).toHaveLength(1);
    expect((await pullAll()).items[0]!.updatedAt).toBe(T0);
  });
});

describe("sync – pagination", () => {
  it("pages of `limit` with hasMore and a resumable cursor", async () => {
    await push(Array.from({ length: 7 }, (_, i) => fav(String(i), T0 + i)));
    const p1 = await pull(0, 3);
    expect(p1.json.items).toHaveLength(3);
    expect(p1.json.hasMore).toBe(true);
    const p2 = await pull(p1.json.cursor, 3);
    expect(p2.json.items).toHaveLength(3);
    expect(p2.json.hasMore).toBe(true);
    const p3 = await pull(p2.json.cursor, 3);
    expect(p3.json.items).toHaveLength(1);
    expect(p3.json.hasMore).toBe(false);
    const keys = [...p1.json.items, ...p2.json.items, ...p3.json.items].map((i: { key: string }) => i.key);
    expect(new Set(keys).size).toBe(7);
  });

  it("limit defaults to and is capped at 500", async () => {
    await push(Array.from({ length: 500 }, (_, i) => fav(String(i), T0)));
    await push(Array.from({ length: 20 }, (_, i) => fav(`x${i}`, T0)));
    const d = await h.get("/v1/sync", { token });
    expect(d.json.items).toHaveLength(500);
    expect(d.json.hasMore).toBe(true);
    const capped = await pull(0, 10_000);
    expect(capped.json.items).toHaveLength(500);
    const rest = await pull(capped.json.cursor, 10_000);
    expect(rest.json.items).toHaveLength(20);
    expect(rest.json.hasMore).toBe(false);
  });
});

describe("sync – limits", () => {
  it("at most 5 000 live favorites per account (deletes free slots)", async () => {
    for (let b = 0; b < 10; b++) {
      const r = await push(Array.from({ length: 500 }, (_, i) => fav(`${b}-${i}`, T0)));
      expect(r.json.applied).toBe(500);
    }
    const over = await push([fav("new-1", T0), fav("new-2", T0)]);
    expect(over.json.applied).toBe(0);
    expect(over.json.rejected).toEqual([
      { key: fav("new-2", 0).key, reason: "favorites_limit" },
      { key: fav("new-1", 0).key, reason: "favorites_limit" },
    ]);
    // updating an existing favorite is still allowed
    expect((await push([fav("0-0", T0 + 1)])).json.applied).toBe(1);
    // delete one + add one in the same request
    const swap = await push([fav("0-1", T0 + 1, { deleted: true }), fav("new-1", T0 + 1)]);
    expect(swap.json.applied).toBe(2);
    expect(swap.json.rejected).toBeUndefined();
  }, 60_000);

  it("at most 2 000 progress items: the oldest are trimmed", async () => {
    for (let b = 0; b < 4; b++) {
      await push(Array.from({ length: 500 }, (_, i) => prog(`${b}-${i}`, T0 - 10 * DAY + b * 1000 + i)));
    }
    const r = await push([prog("newest", T0)]);
    expect(r.json.applied).toBe(1);
    const all = (await pullAll()).items.filter((i) => i.kind === "progress" && !i.deleted);
    expect(all).toHaveLength(2000);
    const keys = new Set(all.map((i) => i.key as string));
    expect(keys.has(prog("newest", 0).key)).toBe(true);
    expect(keys.has(prog("0-0", 0).key)).toBe(false); // oldest trimmed
    expect(keys.has(prog("0-1", 0).key)).toBe(true);
  }, 60_000);
});
