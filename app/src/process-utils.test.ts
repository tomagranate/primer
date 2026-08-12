import { describe, expect, test } from "bun:test";
import { parseProcessTree } from "./process-utils";

describe("parseProcessTree", () => {
  test("groups children by parent and ignores malformed records", () => {
    expect(parseProcessTree([" 20 10", "21 10", "30 20", "nope", ""])).toEqual(
      new Map([
        [10, [20, 21]],
        [20, [30]],
      ]),
    );
  });
});
