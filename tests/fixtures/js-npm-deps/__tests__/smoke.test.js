import { describe, it, expect } from "vitest";
import ms from "ms";

describe("ms dependency", () => {
  it("is installed and importable", () => {
    expect(ms("2 days")).toBe(172800000);
  });
});
