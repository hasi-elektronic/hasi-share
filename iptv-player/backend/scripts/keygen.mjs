#!/usr/bin/env node
// Generates the ES256 (P-256) license signing key pair (CONTRACT §7.2).
//
//   node scripts/keygen.mjs [--kid <id>] [--write-clients] [--replace] [--force]
//                           [--keys-dir <dir>] [--out-root <dir>]
//
// * Private key: PKCS#8 PEM → <keys-dir>/license-private.pem (mode 600, git-ignored).
//   Upload it with: npx wrangler secret put LICENSE_SIGNING_KEY < .keys/license-private.pem
// * Public key:  JWK set {"<kid>": {kty, crv, x, y}} → <keys-dir>/license-public.json and
//   (with --write-clients) into the apps' embedded key files, relative to <out-root>
//   (default: the iptv-player/ directory):
//     android/app/src/main/assets/license-keys.json
//     apple/Config/license-keys.json
//   Existing kids in those files are kept (key rotation: old tokens stay verifiable)
//   unless --replace is given.
//
// No dependencies (Node >= 20, WebCrypto).
import { webcrypto } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const subtle = webcrypto.subtle;
const backendDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const KID_RE = /^[A-Za-z0-9._-]{1,64}$/;
export const CLIENT_KEY_FILES = ["android/app/src/main/assets/license-keys.json", "apple/Config/license-keys.json"];

function usage() {
  return `Usage: node scripts/keygen.mjs [options]

Options:
  --kid <id>          Key id embedded in tokens (default: LICENSE_KID from wrangler.toml, else "lk-1")
  --write-clients     Also write the public key into the Android and Apple key files
  --replace           Client key files contain only the new key (default: merge, keep other kids)
  --force             Overwrite an existing private key file / a different key with the same kid
  --keys-dir <dir>    Where license-private.pem and license-public.json go (default: backend/.keys)
  --out-root <dir>    Root for the client key files (default: the iptv-player/ directory)
  -h, --help          Show this help`;
}

function parseArgs(argv) {
  const o = { kid: null, writeClients: false, replace: false, force: false, keysDir: join(backendDir, ".keys"), outRoot: resolve(backendDir, "..") };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => {
      const v = argv[++i];
      if (v === undefined || v.startsWith("--")) throw new Error(`${a} needs a value`);
      return v;
    };
    if (a === "--kid") o.kid = val();
    else if (a.startsWith("--kid=")) o.kid = a.slice(6);
    else if (a === "--write-clients") o.writeClients = true;
    else if (a === "--replace") o.replace = true;
    else if (a === "--force") o.force = true;
    else if (a === "--keys-dir") o.keysDir = resolve(val());
    else if (a === "--out-root") o.outRoot = resolve(val());
    else if (a === "-h" || a === "--help") o.help = true;
    else throw new Error(`unknown argument: ${a}`);
  }
  return o;
}

function defaultKid() {
  try {
    const toml = readFileSync(join(backendDir, "wrangler.toml"), "utf8");
    const m = /^\s*LICENSE_KID\s*=\s*"([^"]+)"/m.exec(toml);
    if (m) return m[1];
  } catch {
    /* no wrangler.toml */
  }
  return "lk-1";
}

function toPem(der, label) {
  const b64 = Buffer.from(der).toString("base64");
  return `-----BEGIN ${label}-----\n${b64.match(/.{1,64}/g).join("\n")}\n-----END ${label}-----\n`;
}

function readJson(path) {
  if (!existsSync(path)) return null;
  const v = JSON.parse(readFileSync(path, "utf8"));
  if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error(`${path} is not a JWK set object`);
  return v;
}

const sameKey = (a, b) => a && b && a.kty === b.kty && a.crv === b.crv && a.x === b.x && a.y === b.y;

function writeJson(path, obj) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(obj, null, 2)}\n`);
}

export async function generate() {
  const kp = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = new Uint8Array(await subtle.exportKey("pkcs8", kp.privateKey));
  const pub = await subtle.exportKey("jwk", kp.publicKey);
  return { privatePem: toPem(pkcs8, "PRIVATE KEY"), publicJwk: { kty: "EC", crv: "P-256", x: pub.x, y: pub.y } };
}

export async function main(argv = process.argv.slice(2), log = console.log) {
  const o = parseArgs(argv);
  if (o.help) {
    log(usage());
    return null;
  }
  const kid = o.kid ?? defaultKid();
  if (!KID_RE.test(kid)) throw new Error(`invalid --kid "${kid}" (allowed: A-Z a-z 0-9 . _ -, max 64)`);

  const privPath = join(o.keysDir, "license-private.pem");
  if (existsSync(privPath) && !o.force) {
    throw new Error(`${privPath} already exists. Use --force to replace it (the old key can then no longer sign).`);
  }
  // Check client files before writing anything.
  const clientPaths = o.writeClients ? CLIENT_KEY_FILES.map((f) => join(o.outRoot, f)) : [];
  const existing = clientPaths.map(readJson);
  for (const [i, set] of existing.entries()) {
    if (set && set[kid] && !o.force && !o.replace) {
      throw new Error(`${clientPaths[i]} already contains kid "${kid}". Choose a new --kid (rotation) or pass --force.`);
    }
  }

  const { privatePem, publicJwk } = await generate();
  mkdirSync(o.keysDir, { recursive: true });
  writeFileSync(privPath, privatePem, { mode: 0o600 });
  chmodSync(privPath, 0o600);
  const publicSet = { [kid]: publicJwk };
  writeJson(join(o.keysDir, "license-public.json"), publicSet);

  const written = [];
  for (const [i, path] of clientPaths.entries()) {
    const set = o.replace ? {} : { ...(existing[i] ?? {}) };
    if (!sameKey(set[kid], publicJwk)) set[kid] = publicJwk;
    writeJson(path, set);
    written.push(path);
  }

  const rel = (p) => relative(process.cwd(), p) || p;
  log(`License signing key generated (ES256 / P-256), kid "${kid}".

Public JWK set (embedded in the apps):
${JSON.stringify(publicSet, null, 2)}

Files:
  private key (SECRET, never commit): ${rel(privPath)}
  public key set:                     ${rel(join(o.keysDir, "license-public.json"))}
${written.map((p) => `  client key file:                    ${rel(p)}`).join("\n") || "  (client key files not written – run with --write-clients)"}

Next steps:
  1. npx wrangler secret put LICENSE_SIGNING_KEY < ${rel(privPath)}
  2. Make sure wrangler.toml has LICENSE_KID = "${kid}", then: npx wrangler deploy
  3. Rebuild both apps so they embed the new public key${o.writeClients ? "" : " (run again with --write-clients, or copy the JWK set above)"}.
  4. Keep the old kid in the client files until no released app version needs it.`);
  return { kid, privPath, publicJwk, written };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(`keygen: ${e.message}`);
    process.exit(1);
  });
}
