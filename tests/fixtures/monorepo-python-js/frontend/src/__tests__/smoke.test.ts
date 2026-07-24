import { describe, it, expect } from "vitest";
import { greet } from "@/greet";

describe("greet", () => {
  it("resolves the @ alias and greets", () => {
    expect(greet("world")).toBe("hello, world");
  });
});
