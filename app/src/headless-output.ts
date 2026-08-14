export function shouldPrintLogs(dryRun: boolean, event: string): boolean {
  return dryRun || event === "failed";
}
