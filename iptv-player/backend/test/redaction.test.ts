import { describe, expect, it } from "vitest";
import vectors from "../../spec/test-vectors/redaction.json";
import { Logger, maskEmails, redact } from "../src/log";

describe("redact() – CONTRACT §10 vectors", () => {
  for (const [i, c] of vectors.cases.entries()) {
    it(`case ${i}: ${c.input.slice(0, 40)}`, () => {
      expect(redact(c.input, c.secrets)).toBe(c.expected);
    });
  }
});

describe("Logger", () => {
  it("redacts every line, masks e-mails and registered secrets", () => {
    const lines: string[] = [];
    const log = new Logger(["super-secret-admin-token"], "info", { req: "r1" }, (_l, line) => lines.push(line));
    log.info("test", {
      email: "alice.smith@example.com",
      header: "Authorization: Bearer abc.def",
      url: "http://h/live/user/pass/1.ts?token=xyz",
      note: "admin super-secret-admin-token used",
    });
    log.debug("hidden");
    expect(lines).toHaveLength(1);
    const line = lines[0]!;
    expect(line).not.toContain("alice.smith");
    expect(line).toContain("a***@example.com");
    expect(line).toContain("Bearer ***");
    expect(line).toContain("/live/***/***/");
    expect(line).toContain("token=***");
    expect(line).not.toContain("super-secret-admin-token");
    expect(JSON.parse(line).req).toBe("r1");
  });

  it("maskEmails keeps redaction output intact", () => {
    expect(maskEmails("http://***@cam.example.com/x")).toBe("http://***@cam.example.com/x");
    expect(maskEmails("to bob@test.io now")).toBe("to b***@test.io now");
  });
});
