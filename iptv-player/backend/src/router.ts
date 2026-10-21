import type { Handler } from "./http";

interface Route {
  method: string;
  segments: string[];
  handler: Handler;
}

export type MatchResult =
  | { kind: "found"; handler: Handler; params: Record<string, string> }
  | { kind: "method_not_allowed"; allow: string[] }
  | { kind: "not_found" };

/** Minimal path router: static segments and `:param` segments, exact length match. */
export class Router {
  private readonly routes: Route[] = [];

  add(method: string, path: string, handler: Handler): this {
    this.routes.push({ method: method.toUpperCase(), segments: split(path), handler });
    return this;
  }
  get(path: string, h: Handler): this {
    return this.add("GET", path, h);
  }
  post(path: string, h: Handler): this {
    return this.add("POST", path, h);
  }
  put(path: string, h: Handler): this {
    return this.add("PUT", path, h);
  }
  delete(path: string, h: Handler): this {
    return this.add("DELETE", path, h);
  }

  match(method: string, pathname: string): MatchResult {
    const parts = split(pathname);
    const allow = new Set<string>();
    const m = method.toUpperCase() === "HEAD" ? "GET" : method.toUpperCase();
    for (const r of this.routes) {
      const params = matchSegments(r.segments, parts);
      if (!params) continue;
      if (r.method === m) return { kind: "found", handler: r.handler, params };
      allow.add(r.method);
    }
    if (allow.size > 0) return { kind: "method_not_allowed", allow: [...allow] };
    return { kind: "not_found" };
  }
}

function split(path: string): string[] {
  return path.split("/").filter((s) => s.length > 0);
}

function matchSegments(pattern: string[], parts: string[]): Record<string, string> | null {
  if (pattern.length !== parts.length) return null;
  const params: Record<string, string> = {};
  for (let i = 0; i < pattern.length; i++) {
    const p = pattern[i]!;
    const v = parts[i]!;
    if (p.startsWith(":")) {
      let decoded: string;
      try {
        decoded = decodeURIComponent(v);
      } catch {
        return null;
      }
      params[p.slice(1)] = decoded;
    } else if (p !== v) {
      return null;
    }
  }
  return params;
}
