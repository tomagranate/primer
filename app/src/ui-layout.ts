import { wrapSegments, wrapText } from "./text-layout";

export interface AddonPickerLine {
  kind: "label" | "description";
  text: string;
  first: boolean;
}

export function addonPickerLines(label: string, description: string, width: number): AddonPickerLine[] {
  const contentWidth = Math.max(1, width - 6);
  const labels = wrapText(label, contentWidth);
  const descriptions = description.trim() ? wrapText(description, contentWidth) : [];
  return [
    ...labels.map((text, index): AddonPickerLine => ({ kind: "label", text, first: index === 0 })),
    ...descriptions.map((text): AddonPickerLine => ({ kind: "description", text, first: false })),
  ];
}

export interface SummaryLine {
  label: string;
  metadata: string;
  first: boolean;
  stacked: boolean;
}

export interface SummaryLayout {
  labelWidth: number;
  lines: SummaryLine[];
}

/** Lay out one summary entry without letting metadata consume trailing columns. */
export function summaryLines(
  label: string,
  detail: string,
  itemCount: number,
  elapsed: string,
  width: number,
): SummaryLayout {
  const contentWidth = Math.max(1, width - 5);
  const metadata = [detail, itemCount > 0 ? `${itemCount} items` : "", elapsed];

  if (width < 60) {
    const labelLines = wrapText(label, contentWidth);
    const metadataLines = wrapSegments(metadata, contentWidth);
    return {
      labelWidth: contentWidth,
      lines: [
        ...labelLines.map((text, index): SummaryLine => ({
          label: text,
          metadata: "",
          first: index === 0,
          stacked: true,
        })),
        ...metadataLines.filter(Boolean).map((text): SummaryLine => ({
          label: "",
          metadata: text,
          first: false,
          stacked: true,
        })),
      ],
    };
  }

  const labelWidth = Math.max(12, Math.min(20, Math.floor(contentWidth * 0.36)));
  const metadataWidth = Math.max(1, contentWidth - labelWidth);
  const labelLines = wrapText(label, labelWidth);
  const metadataLines = wrapSegments(metadata, metadataWidth);
  const height = Math.max(labelLines.length, metadataLines.length);
  return {
    labelWidth,
    lines: Array.from({ length: height }, (_, index) => ({
      label: labelLines[index] ?? "",
      metadata: metadataLines[index] ?? "",
      first: index === 0,
      stacked: false,
    })),
  };
}
