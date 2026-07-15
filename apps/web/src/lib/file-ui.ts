import {
  File as FileIcon,
  FileArchive,
  FileCode,
  FileSpreadsheet,
  FileText,
  Image as ImageIcon,
  type LucideIcon,
} from "lucide-react";

export function fileIcon(file: File | { name: string; type?: string }): LucideIcon {
  const type = "type" in file ? (file.type ?? "") : "";
  const ext = file.name.split(".").pop()?.toLowerCase() ?? "";
  if (type.startsWith("image/")) return ImageIcon;
  if (["csv", "xlsx", "xls"].includes(ext)) return FileSpreadsheet;
  if (["zip", "tar", "gz", "rar"].includes(ext)) return FileArchive;
  if (["js", "ts", "tsx", "py", "ex", "rb", "go", "json", "html", "css"].includes(ext))
    return FileCode;
  if (type.startsWith("text/") || ["pdf", "doc", "docx", "md"].includes(ext)) return FileText;
  return FileIcon;
}

export function formatFileSize(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}
