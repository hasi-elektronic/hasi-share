// Tests for scripts/keygen.mjs (Node's built-in test runner; run by `npm test`).
// Everything is written into a temporary directory – never into the real app folders.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { webcrypto } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

const script = join(dirname(fileURLToPath(import.meta.url)), "keygen.mjs");
const subtle = webcrypto.subtle;
let root;

before(() => {
  root = mkdtempSync(join(tmpdir(), "keygen-test-"));
});
after(() => rmSync(root, { recursive: true, force: true }));

const run = (args) => execFileSync(process.execPath, [script, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
const runFails = (args) => {
  try {
    run(args);
  } catch (e) {
    return String(e.stderr);
  }
  assert.fail(`expected failure for ${args.join(" ")}`);
};
const readJson = (p) => JSON.parse(readFileSync(p, "utf8"));
const ANDROID = "android/app/src/main/assets/license-keys.json";
const APPLE = "apple/Config/license-keys.json";

function pemToDer(pem) {
  return Buffer.from(pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, ""), "base64");
}

async function signVerifies(pem, jwk) {
  const priv = await subtle.importKey("pkcs8", pemToDer(pem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const pub = await subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  const data = new TextEncoder().encode("header.payload");
  const sig = await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, priv, data);
  assert.equal(sig.byteLength, 64); // raw r||s, as used in the license JWS
  return subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pub, sig, data);
}

test("generates PKCS#8 PEM + public JWK set and writes both client files", async () => {
  const keys = join(root, "a", "keys");
  const out = join(root, "a", "repo");
  const stdout = run(["--kid", "lk-test", "--write-clients", "--keys-dir", keys, "--out-root", out]);
  assert.match(stdout, /wrangler secret put LICENSE_SIGNING_KEY/);
  assert.match(stdout, /LICENSE_KID = "lk-test"/);

  const pem = readFileSync(join(keys, "license-private.pem"), "utf8");
  assert.match(pem, /^-----BEGIN PRIVATE KEY-----\n/);
  assert.match(pem, /\n-----END PRIVATE KEY-----\n$/);
  assert.ok(!stdout.includes(pem.split("\n")[1]), "private key must not be printed");
  if (process.platform !== "win32") assert.equal(statSync(join(keys, "license-private.pem")).mode & 0o777, 0o600);

  const pub = readJson(join(keys, "license-public.json"));
  assert.deepEqual(Object.keys(pub), ["lk-test"]);
  const jwk = pub["lk-test"];
  // Same shape as spec/test-vectors/license-token.json `keys` (CONTRACT §7.2).
  assert.deepEqual(Object.keys(jwk), ["kty", "crv", "x", "y"]);
  assert.equal(jwk.kty, "EC");
  assert.equal(jwk.crv, "P-256");
  assert.match(jwk.x, /^[A-Za-z0-9_-]{43}$/);
  assert.match(jwk.y, /^[A-Za-z0-9_-]{43}$/);

  for (const f of [ANDROID, APPLE]) assert.deepEqual(readJson(join(out, f)), pub);
  assert.equal(await signVerifies(pem, jwk), true);
});

test("default kid comes from wrangler.toml LICENSE_KID; nothing written to clients without --write-clients", () => {
  const keys = join(root, "b", "keys");
  const out = join(root, "b", "repo");
  run(["--keys-dir", keys, "--out-root", out]);
  const toml = readFileSync(join(dirname(script), "..", "wrangler.toml"), "utf8");
  const kid = /LICENSE_KID\s*=\s*"([^"]+)"/.exec(toml)[1];
  assert.deepEqual(Object.keys(readJson(join(keys, "license-public.json"))), [kid]);
  assert.equal(existsSync(join(out, ANDROID)), false);
  assert.equal(existsSync(join(out, APPLE)), false);
});

test("rotation: a new kid is merged into existing client files; --replace keeps only the new one", () => {
  const out = join(root, "c", "repo");
  run(["--kid", "k1", "--write-clients", "--keys-dir", join(root, "c", "k1"), "--out-root", out]);
  run(["--kid", "k2", "--write-clients", "--keys-dir", join(root, "c", "k2"), "--out-root", out]);
  const merged = readJson(join(out, ANDROID));
  assert.deepEqual(Object.keys(merged).sort(), ["k1", "k2"]);
  assert.deepEqual(readJson(join(out, APPLE)), merged);
  run(["--kid", "k3", "--write-clients", "--replace", "--keys-dir", join(root, "c", "k3"), "--out-root", out]);
  assert.deepEqual(Object.keys(readJson(join(out, APPLE))), ["k3"]);
});

test("refuses to overwrite a private key or an existing kid without --force", () => {
  const keys = join(root, "d", "keys");
  const out = join(root, "d", "repo");
  run(["--kid", "same", "--write-clients", "--keys-dir", keys, "--out-root", out]);
  const before = readFileSync(join(keys, "license-private.pem"), "utf8");
  assert.match(runFails(["--kid", "other", "--keys-dir", keys, "--out-root", out]), /already exists/);
  assert.match(runFails(["--kid", "same", "--write-clients", "--keys-dir", join(root, "d", "k2"), "--out-root", out]), /already contains kid "same"/);
  assert.equal(readFileSync(join(keys, "license-private.pem"), "utf8"), before);
  run(["--kid", "same", "--write-clients", "--force", "--keys-dir", keys, "--out-root", out]);
  assert.notEqual(readFileSync(join(keys, "license-private.pem"), "utf8"), before);
  assert.deepEqual(Object.keys(readJson(join(out, ANDROID))), ["same"]);
});

test("rejects invalid kids, unknown flags and malformed client files", () => {
  const keys = join(root, "e", "keys");
  assert.match(runFails(["--kid", "bad kid!", "--keys-dir", keys]), /invalid --kid/);
  assert.match(runFails(["--bogus"]), /unknown argument/);
  const out = join(root, "e", "repo");
  mkdirSync(join(out, "apple/Config"), { recursive: true });
  writeFileSync(join(out, APPLE), "[1,2]");
  assert.match(runFails(["--kid", "x", "--write-clients", "--keys-dir", keys, "--out-root", out]), /not a JWK set object/);
  assert.equal(existsSync(join(keys, "license-private.pem")), false, "nothing written on validation errors");
  assert.match(run(["--help"]), /Usage:/);
});
