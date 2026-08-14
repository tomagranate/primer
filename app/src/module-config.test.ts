import { describe, expect, test } from "bun:test";
import { renderModuleConfig, zshQuote } from "./module-config";

describe("module configuration serialization", () => {
  test("quotes shell metacharacters without executing them", () => {
    expect(zshQuote('a $HOME `command` "quote" \\ path'))
      .toBe('"a \\$HOME \\`command\\` \\"quote\\" \\\\ path"');
  });

  test("renders the associative array used by Zsh modules", () => {
    expect(renderModuleConfig({ "tool.items": "\none\ntwo" })).toBe(
      'typeset -gA _mod_config=()\n_mod_config[tool.items]="\none\ntwo"\n',
    );
  });
});
