export function zshQuote(value: string): string {
  return `"${value.replace(/[\\$"`]/g, (match) => `\\${match}`)}"`;
}

export function renderModuleConfig(config: Record<string, string>): string {
  const lines = ["typeset -gA _mod_config=()"];
  for (const [key, value] of Object.entries(config)) {
    lines.push(`_mod_config[${key}]=${zshQuote(value)}`);
  }
  return `${lines.join("\n")}\n`;
}
