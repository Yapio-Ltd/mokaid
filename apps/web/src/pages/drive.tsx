import { useState } from "react";
import {
  ChevronRight,
  File,
  FileText,
  Folder,
  FolderPlus,
  HardDrive,
  Home,
  Image,
  LayoutGrid,
  List,
  RotateCcw,
  Sheet,
  Trash2,
  Upload,
} from "lucide-react";
import {
  useCreateFolder,
  useDriveItems,
  useDriveTrash,
  useTrashDriveItem,
} from "@/api/hooks";
import type { DriveItem } from "@/api/types";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { DetailPanel } from "@/components/ui/detail-panel";
import { SkeletonRows } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/ui/empty-state";
import { cn } from "@/lib/cn";
import { formatBytes, formatRelative } from "@/lib/format";

interface Crumb {
  id: string | null;
  name: string;
}

function fileIcon(item: DriveItem) {
  if (item.kind === "folder") return Folder;
  switch (item.extension) {
    case "pdf":
    case "doc":
    case "docx":
    case "md":
      return FileText;
    case "xlsx":
    case "csv":
      return Sheet;
    case "png":
    case "jpg":
    case "svg":
      return Image;
    default:
      return File;
  }
}

export function DrivePage() {
  const [crumbs, setCrumbs] = useState<Crumb[]>([{ id: null, name: "Drive" }]);
  const [view, setView] = useState<"grid" | "list">("grid");
  const [showTrash, setShowTrash] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const currentFolder = crumbs[crumbs.length - 1];
  const { data, isLoading } = useDriveItems(currentFolder.id);
  const { data: trashData } = useDriveTrash();
  const createFolder = useCreateFolder();
  const trashItem = useTrashDriveItem();

  const items = showTrash ? (trashData?.data ?? []) : (data?.data ?? []);
  const selected = items.find((i) => i.id === selectedId) ?? null;

  const openFolder = (item: DriveItem) => {
    if (item.kind === "folder") {
      setCrumbs((prev) => [...prev, { id: item.id, name: item.name }]);
      setSelectedId(null);
    } else {
      setSelectedId(item.id);
    }
  };

  const handleNewFolder = () => {
    const name = window.prompt("Folder name");
    if (name?.trim()) {
      createFolder.mutate({ name: name.trim(), parent_id: currentFolder.id });
    }
  };

  return (
    <div className="flex h-full gap-5">
      <div className="min-w-0 flex-1 space-y-4">
        <div className="flex items-center justify-between gap-3">
          <div>
            <h1 className="text-xl font-bold text-text">Drive</h1>
            <p className="text-xs text-text-muted">Workspace files, folders and agent outputs</p>
          </div>
          <div className="flex items-center gap-2">
            <Button variant="secondary" size="sm" onClick={handleNewFolder}>
              <FolderPlus size={14} /> New Folder
            </Button>
            <Button size="sm">
              <Upload size={14} /> Upload
            </Button>
          </div>
        </div>

        <div className="flex items-center justify-between gap-3">
          {/* Breadcrumbs */}
          <nav className="flex min-w-0 items-center gap-1 text-xs" aria-label="Breadcrumb">
            {showTrash ? (
              <span className="flex items-center gap-1.5 font-medium text-text">
                <Trash2 size={13} /> Trash
              </span>
            ) : (
              crumbs.map((crumb, index) => (
                <span key={crumb.id ?? "root"} className="flex items-center gap-1">
                  {index > 0 && <ChevronRight size={12} className="text-text-muted" />}
                  <button
                    onClick={() => setCrumbs(crumbs.slice(0, index + 1))}
                    className={cn(
                      "flex items-center gap-1 rounded px-1.5 py-0.5 transition-colors hover:bg-surface-hover",
                      index === crumbs.length - 1
                        ? "font-semibold text-text"
                        : "text-text-muted hover:text-text",
                    )}
                  >
                    {index === 0 && <Home size={12} />}
                    {crumb.name}
                  </button>
                </span>
              ))
            )}
          </nav>

          <div className="flex items-center gap-2">
            <button
              onClick={() => {
                setShowTrash(!showTrash);
                setSelectedId(null);
              }}
              className={cn(
                "flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-medium transition-colors",
                showTrash
                  ? "bg-danger/10 text-danger"
                  : "text-text-muted hover:bg-surface-hover hover:text-text",
              )}
            >
              <Trash2 size={13} /> Trash
            </button>
            <div className="flex rounded-md border border-border bg-surface p-0.5">
              <button
                onClick={() => setView("grid")}
                aria-label="Grid view"
                className={cn(
                  "rounded p-1.5 transition-colors",
                  view === "grid" ? "bg-primary-muted text-primary-light" : "text-text-muted",
                )}
              >
                <LayoutGrid size={14} />
              </button>
              <button
                onClick={() => setView("list")}
                aria-label="List view"
                className={cn(
                  "rounded p-1.5 transition-colors",
                  view === "list" ? "bg-primary-muted text-primary-light" : "text-text-muted",
                )}
              >
                <List size={14} />
              </button>
            </div>
          </div>
        </div>

        {isLoading ? (
          <SkeletonRows rows={5} />
        ) : items.length === 0 ? (
          <EmptyState
            icon={<HardDrive size={24} />}
            title={showTrash ? "Trash is empty" : "This folder is empty"}
            description={showTrash ? undefined : "Upload files or create folders to get started."}
          />
        ) : view === "grid" ? (
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5">
            {items.map((item) => {
              const Icon = fileIcon(item);
              return (
                <button
                  key={item.id}
                  onClick={() => (showTrash ? setSelectedId(item.id) : openFolder(item))}
                  onDoubleClick={() => !showTrash && openFolder(item)}
                  className={cn(
                    "mk-card flex flex-col items-center gap-2 p-4 text-center transition-shadow hover:shadow-glow mk-focus-ring",
                    selectedId === item.id && "border-primary/50",
                  )}
                >
                  <Icon
                    size={32}
                    className={item.kind === "folder" ? "text-primary-light" : "text-text-muted"}
                    fill={item.kind === "folder" ? "currentColor" : "none"}
                    fillOpacity={item.kind === "folder" ? 0.2 : 0}
                  />
                  <span className="w-full truncate text-xs font-medium text-text">{item.name}</span>
                  <span className="text-[10px] text-text-muted">
                    {item.kind === "folder" ? "Folder" : formatBytes(item.size_bytes)}
                  </span>
                </button>
              );
            })}
          </div>
        ) : (
          <div className="mk-card overflow-hidden">
            <table className="w-full text-left text-xs">
              <thead>
                <tr className="border-b border-border text-[11px] uppercase tracking-wide text-text-muted">
                  <th className="px-5 py-3 font-medium">Name</th>
                  <th className="px-3 py-3 font-medium">Size</th>
                  <th className="px-3 py-3 font-medium">Created by</th>
                  <th className="px-3 py-3 font-medium">AI-readable</th>
                  <th className="px-5 py-3 font-medium">Modified</th>
                </tr>
              </thead>
              <tbody>
                {items.map((item) => {
                  const Icon = fileIcon(item);
                  return (
                    <tr
                      key={item.id}
                      onClick={() => (showTrash ? setSelectedId(item.id) : openFolder(item))}
                      className="cursor-pointer border-b border-border/50 transition-colors last:border-0 hover:bg-surface-hover"
                    >
                      <td className="px-5 py-2.5">
                        <span className="flex items-center gap-2.5 font-medium text-text">
                          <Icon
                            size={16}
                            className={
                              item.kind === "folder" ? "text-primary-light" : "text-text-muted"
                            }
                          />
                          {item.name}
                        </span>
                      </td>
                      <td className="px-3 py-2.5 text-text-muted">
                        {item.kind === "folder" ? "·" : formatBytes(item.size_bytes)}
                      </td>
                      <td className="px-3 py-2.5 text-text-secondary">
                        {item.created_by_name ?? "·"}
                        {item.created_by_kind === "agent" && (
                          <Badge tone="primary" className="ml-1.5">
                            AI
                          </Badge>
                        )}
                      </td>
                      <td className="px-3 py-2.5">
                        {item.is_ai_readable ? <Badge tone="success">Yes</Badge> : <Badge tone="muted">No</Badge>}
                      </td>
                      <td className="px-5 py-2.5 text-text-muted">
                        {formatRelative(item.updated_at)}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <DetailPanel
        open={selected != null}
        onClose={() => setSelectedId(null)}
        title={selected?.kind === "folder" ? "Folder Details" : "File Details"}
      >
        {selected && (
          <div className="space-y-5 px-5 py-4">
            <div className="flex flex-col items-center gap-2 py-3">
              {(() => {
                const Icon = fileIcon(selected);
                return (
                  <Icon
                    size={44}
                    className={selected.kind === "folder" ? "text-primary-light" : "text-text-muted"}
                  />
                );
              })()}
              <h3 className="max-w-full truncate text-sm font-bold text-text">{selected.name}</h3>
              <div className="flex gap-2">
                <Badge tone="muted" className="capitalize">
                  {selected.visibility.replace("_", " ")}
                </Badge>
                {selected.is_ai_readable && <Badge tone="success">AI-readable</Badge>}
                {selected.is_system_folder && <Badge tone="primary">System</Badge>}
              </div>
            </div>

            <div className="space-y-1.5 text-xs">
              <div className="flex justify-between">
                <span className="text-text-muted">Size</span>
                <span className="text-text">
                  {selected.kind === "folder" ? "·" : formatBytes(selected.size_bytes)}
                </span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">Versions</span>
                <span className="text-text">{selected.version_count}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">Created by</span>
                <span className="text-text">{selected.created_by_name ?? "·"}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">Modified</span>
                <span className="text-text">{formatRelative(selected.updated_at)}</span>
              </div>
            </div>

            {selected.tags.length > 0 && (
              <div className="flex flex-wrap gap-1.5">
                {selected.tags.map((tag) => (
                  <Badge key={tag} tone="primary">
                    {tag}
                  </Badge>
                ))}
              </div>
            )}

            {showTrash ? (
              <Button variant="secondary" size="sm" className="w-full">
                <RotateCcw size={13} /> Restore
              </Button>
            ) : (
              <Button
                variant="danger"
                size="sm"
                className="w-full"
                loading={trashItem.isPending}
                onClick={() =>
                  trashItem.mutate(selected.id, { onSuccess: () => setSelectedId(null) })
                }
              >
                <Trash2 size={13} /> Move to Trash
              </Button>
            )}
          </div>
        )}
      </DetailPanel>
    </div>
  );
}
