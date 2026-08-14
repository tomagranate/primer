import { describe, expect, test } from "bun:test";
import { shouldPrintLogs } from "./headless-output";

describe("headless output", () => {
  test("prints all dry-run logs", () => {
    expect(shouldPrintLogs(true, "done")).toBe(true);
  });

  test("prints failed wet-run logs", () => {
    expect(shouldPrintLogs(false, "failed")).toBe(true);
  });

  test("does not print successful wet-run logs", () => {
    expect(shouldPrintLogs(false, "done")).toBe(false);
  });
});
