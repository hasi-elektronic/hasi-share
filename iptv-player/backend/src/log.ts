/**
 * Structured logging. Every line passes `redact()` (CONTRACT §10) and an additional
 * e-mail mask before it reaches the console. Callers must still avoid passing tokens,
 * purchase tokens or pairing ciphertext as fields – redaction is the safety net.
 */

const RULE_USERINFO = /\b([a-z][a-z0-9+.-]*:\/\/)[^/\s@:]+:[^/\s@]*@/gi;
const RULE_PATH_CREDS = /\/(live|movie|series|timeshift)\/[^/\s?#]+\/[^/\s?#]+\//gi;
const RULE_QUERY =
  /\b(username|password|pass|pwd|token|auth|key|apikey|api_key|secret|signature|sig|access_token)=([^&\s#"']*)/gi;
const RULE_BEARER = /(Bearer\s+)[A-Za-z0-9._~+/=-]+/gi;
const EMAIL = /([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})/g;

/** CONTRACT §10 – rules applied in the specified order. */
export function redact(input: string, secrets: readonly string[] = []): string {
  let out = input;
  // 1. registered secret values (length >= 3), longest first, literal replace.
  const sorted = [...new Set(secrets.filter((s) => s.length >= 3))].sort((a, b) => b.length - a.length);
  for (const s of sorted) out = out.split(s).join("***");
  // 2. URL user-info.
  out = out.replace(RULE_USERINFO, "$1***@");
  // 3. Xtream credential path segments.
  out = out.replace(RULE_PATH_CREDS, "/$1/***/***/");
  // 4. credential-like query/key=value pairs.
  out = out.replace(RULE_QUERY, "$1=***");
  // 5. bearer tokens.
  out = out.replace(RULE_BEARER, "$1***");
  return out;
}

/** "alice@example.com" → "a***@example.com" (backend-specific addition to §10). */
export function maskEmails(input: string): string {
  return input.replace(EMAIL, "$1***@$2");
}

export type LogLevel = "debug" | "info" | "warn" | "error";
const LEVELS: Record<LogLevel, number> = { debug: 10, info: 20, warn: 30, error: 40 };

export type LogSink = (level: LogLevel, line: string) => void;

const consoleSink: LogSink = (level, line) => {
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
};

export class Logger {
  constructor(
    private readonly secrets: readonly string[],
    private readonly minLevel: LogLevel = "info",
    private readonly base: Record<string, unknown> = {},
    private readonly sink: LogSink = consoleSink,
  ) {}

  child(fields: Record<string, unknown>): Logger {
    return new Logger(this.secrets, this.minLevel, { ...this.base, ...fields }, this.sink);
  }

  debug(msg: string, fields?: Record<string, unknown>): void {
    this.write("debug", msg, fields);
  }
  info(msg: string, fields?: Record<string, unknown>): void {
    this.write("info", msg, fields);
  }
  warn(msg: string, fields?: Record<string, unknown>): void {
    this.write("warn", msg, fields);
  }
  error(msg: string, fields?: Record<string, unknown>): void {
    this.write("error", msg, fields);
  }

  /** Formats a line exactly as it would be written (exposed for tests). */
  format(level: LogLevel, msg: string, fields?: Record<string, unknown>): string {
    let raw: string;
    try {
      raw = JSON.stringify({ level, msg, ...this.base, ...(fields ?? {}) }, (_k, v: unknown) =>
        v instanceof Error ? { name: v.name, message: v.message } : v,
      );
    } catch {
      raw = JSON.stringify({ level, msg, note: "unserializable fields" });
    }
    return maskEmails(redact(raw, this.secrets));
  }

  private write(level: LogLevel, msg: string, fields?: Record<string, unknown>): void {
    if (LEVELS[level] < LEVELS[this.minLevel]) return;
    this.sink(level, this.format(level, msg, fields));
  }
}
