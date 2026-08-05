import { useEffect, useRef, useState } from "react";
import * as ContextMenu from "@radix-ui/react-context-menu";
import {
  ChevronRight,
  Download,
  File,
  FileText,
  Folder,
  FolderInput,
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
  useDriveItems,
  useDriveTrash,
  useMoveDriveItem,
  useMoveDriveItems,
  useRestoreDriveItem,
  useTrashDriveItem,
  useTrashDriveItems,
  useUploadDriveFile,
} from "@/api/hooks";
import { fetchDriveFileBlob } from "@/api/client";
import { NewFolderModal } from "@/components/modals/new-folder-modal";
import { MoveItemsModal } from "@/components/modals/move-items-modal";
import type { DriveItem } from "@/api/types";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { DetailPanel } from "@/components/ui/detail-panel";
import { PageHeader } from "@/components/ui/page-header";
import { SkeletonRows } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/ui/empty-state";
import { cn } from "@/lib/cn";
import { formatBytes, formatRelative } from "@/lib/format";

interface Crumb {
  id: string | null;
  name: string;
}

const DRAG_MIME = "application/x-mokaid-drive-ids";

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

// File bytes come through the authenticated API (same origin), never from
// the object store directly — browsers may not be able to reach it.
// Images are fetched eagerly for the inline thumbnail.
function DriveThumbnail({ item, size }: { item: DriveItem; size: number }) {
  const isImage = item.kind === "file" && (item.mime_type?.startsWith("image/") ?? false);
  const [blobUrl, setBlobUrl] = useState<string | null>(null);

  useEffect(() => {
    if (!isImage) return;
    let alive = true;
    let url: string | null = null;
    fetchDriveFileBlob(item.id)
      .then((blob) => {
        url = URL.createObjectURL(blob);
        if (alive) setBlobUrl(url);
        else URL.revokeObjectURL(url);
      })
      .catch(() => {
        /* fall back to the generic icon */
      });
    return () => {
      alive = false;
      if (url) URL.revokeObjectURL(url);
    };
  }, [item.id, isImage]);

  if (isImage && blobUrl) {
    return (
      <img
        src={blobUrl}
        alt={item.name}
        className="h-8 w-8 rounded object-cover"
        style={{ height: size, width: size }}
      />
    );
  }

  const Icon = fileIcon(item);
  if (item.kind === "folder") {
    return (
      <span className="flex items-center justify-center rounded-lg bg-primary/10 p-2 text-primary-light">
        <Icon size={size - 8} fill="currentColor" fillOpacity={0.2} />
      </span>
    );
  }
  return <Icon size={size} className="text-text-muted" />;
}

const contextMenuContentClass = "z-50 w-48 rounded-lg bg-surface-overlay p-1.5 shadow-lg";
const contextMenuItemClass =
  "cursor-pointer rounded-md px-2 py-1.5 text-xs text-text outline-none data-[highlighted]:bg-surface-hover flex items-center gap-2";
const contextMenuDangerItemClass =
  "cursor-pointer rounded-md px-2 py-1.5 text-xs text-danger outline-none data-[highlighted]:bg-danger/10 flex items-center gap-2";

interface DriveGridItemProps {
  item: DriveItem;
  index: number;
  isSelected: boolean;
  selectionCount: number;
  draggedIds: string[] | null;
  onClick: (item: DriveItem, e: React.MouseEvent) => void;
  onDoubleClick: (item: DriveItem) => void;
  onDragStartItem: (item: DriveItem) => string[];
  onDropIds: (ids: string[], targetFolderId: string) => void;
  onDropFiles: (files: FileList, targetFolderId: string) => void;
  onOpenMove: () => void;
  onDownload: (item: DriveItem) => void;
  onDelete: () => void;
}

function DriveGridItem({
  item,
  index,
  isSelected,
  selectionCount,
  draggedIds,
  onClick,
  onDoubleClick,
  onDragStartItem,
  onDropIds,
  onDropFiles,
  onOpenMove,
  onDownload,
  onDelete,
}: DriveGridItemProps) {
  const [isDropTarget, setIsDropTarget] = useState(false);
  const isInternalDrag = draggedIds != null;
  const canAcceptDrop =
    item.kind === "folder" && (isInternalDrag ? !draggedIds.includes(item.id) : true);

  return (
    <ContextMenu.Root>
      <ContextMenu.Trigger asChild>
        <button
          draggable
          onDragStart={(e) => {
            const ids = onDragStartItem(item);
            e.dataTransfer.setData(DRAG_MIME, JSON.stringify(ids));
            e.dataTransfer.effectAllowed = "move";
          }}
          onDragOver={(e) => {
            // Only folders accept drops, and only for an internal item drag
            // or files being dragged in from the OS (e.g. Finder/Explorer).
            if (item.kind !== "folder") return;
            if (!isInternalDrag && !e.dataTransfer.types.includes("Files")) return;
            e.preventDefault();
            e.dataTransfer.dropEffect = "move";
          }}
          onDragEnter={(e) => {
            if (item.kind !== "folder") return;
            if (!isInternalDrag && !e.dataTransfer.types.includes("Files")) return;
            setIsDropTarget(true);
          }}
          onDragLeave={() => setIsDropTarget(false)}
          onDrop={(e) => {
            if (item.kind !== "folder") return;
            e.preventDefault();
            setIsDropTarget(false);
            if (e.dataTransfer.files.length > 0) {
              onDropFiles(e.dataTransfer.files, item.id);
              return;
            }
            if (!canAcceptDrop) return;
            const raw = e.dataTransfer.getData(DRAG_MIME);
            if (!raw) return;
            const ids = JSON.parse(raw) as string[];
            onDropIds(ids, item.id);
          }}
          onClick={(e) => onClick(item, e)}
          onDoubleClick={() => onDoubleClick(item)}
          className={cn(
            "mk-tile mk-fade-up flex flex-col items-center gap-2 rounded-xl p-4 text-center mk-focus-ring",
            isSelected && "border-primary/50 bg-primary-muted/30",
            isDropTarget && "border-primary bg-primary-muted/50 ring-2 ring-primary/40",
          )}
          style={{ animationDelay: `${Math.min(index, 10) * 30}ms` }}
        >
          <DriveThumbnail item={item} size={32} />
          <span className="w-full truncate text-xs font-medium text-text">{item.name}</span>
          <span className="text-[10px] text-text-muted">
            {item.kind === "folder" ? "Folder" : formatBytes(item.size_bytes)}
          </span>
        </button>
      </ContextMenu.Trigger>
      <ContextMenu.Portal>
        <ContextMenu.Content className={contextMenuContentClass}>
          {isSelected && selectionCount > 1 ? (
            <div className="px-2 py-1.5 text-[11px] text-text-muted">
              {selectionCount} items selected
            </div>
          ) : null}
          {(!isSelected || selectionCount <= 1) && item.kind === "file" && (
            <ContextMenu.Item className={contextMenuItemClass} onSelect={() => onDownload(item)}>
              <Download size={13} /> Download
            </ContextMenu.Item>
          )}
          <ContextMenu.Item className={contextMenuItemClass} onSelect={onOpenMove}>
            <FolderInput size={13} /> Move to…
          </ContextMenu.Item>
          <ContextMenu.Item className={contextMenuDangerItemClass} onSelect={onDelete}>
            <Trash2 size={13} /> Move to Trash
          </ContextMenu.Item>
        </ContextMenu.Content>
      </ContextMenu.Portal>
    </ContextMenu.Root>
  );
}

export function DrivePage() {
  const [crumbs, setCrumbs] = useState<Crumb[]>([{ id: null, name: "Drive" }]);
  const [view, setView] = useState<"grid" | "list">("grid");
  const [showTrash, setShowTrash] = useState(false);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [anchorId, setAnchorId] = useState<string | null>(null);
  const [showNewFolder, setShowNewFolder] = useState(false);
  const [showMoveModal, setShowMoveModal] = useState(false);
  const [draggedIds, setDraggedIds] = useState<string[] | null>(null);
  const [breadcrumbDropId, setBreadcrumbDropId] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const currentFolder = crumbs[crumbs.length - 1];
  const { data, isLoading } = useDriveItems(currentFolder.id);
  const { data: trashData } = useDriveTrash();
  const trashItem = useTrashDriveItem();
  const trashItems = useTrashDriveItems();
  const restoreItem = useRestoreDriveItem();
  const uploadFile = useUploadDriveFile();
  const moveItem = useMoveDriveItem();
  const moveItems = useMoveDriveItems();

  const items = showTrash ? (trashData?.data ?? []) : (data?.data ?? []);
  const selected =
    selectedIds.length === 1 ? (items.find((i) => i.id === selectedIds[0]) ?? null) : null;

  useEffect(() => {
    setSelectedIds([]);
    setAnchorId(null);
  }, [currentFolder.id, showTrash]);

  const openFolder = (item: DriveItem) => {
    if (item.kind === "folder") {
      setCrumbs((prev) => [...prev, { id: item.id, name: item.name }]);
    } else {
      setSelectedIds([item.id]);
      setAnchorId(item.id);
    }
  };

  const handleItemClick = (item: DriveItem, e: React.MouseEvent) => {
    const hasModifier = e.shiftKey || e.metaKey || e.ctrlKey;

    if (showTrash) {
      setSelectedIds([item.id]);
      return;
    }

    // A plain click on a folder (no modifier) opens it immediately, same as
    // before multi-select existed — modifiers are needed to select folders
    // without navigating into them (e.g. to drag or bulk-delete them).
    if (item.kind === "folder" && !hasModifier) {
      openFolder(item);
      return;
    }

    if (e.shiftKey && anchorId) {
      const anchorIdx = items.findIndex((i) => i.id === anchorId);
      const targetIdx = items.findIndex((i) => i.id === item.id);
      if (anchorIdx !== -1 && targetIdx !== -1) {
        const [start, end] = anchorIdx < targetIdx ? [anchorIdx, targetIdx] : [targetIdx, anchorIdx];
        setSelectedIds(items.slice(start, end + 1).map((i) => i.id));
        return;
      }
    }
    if (e.metaKey || e.ctrlKey) {
      setSelectedIds((prev) =>
        prev.includes(item.id) ? prev.filter((id) => id !== item.id) : [...prev, item.id],
      );
      setAnchorId(item.id);
      return;
    }
    setSelectedIds([item.id]);
    setAnchorId(item.id);
  };

  const handleUploadChange = (files: FileList | null) => {
    if (!files) return;
    Array.from(files).forEach((file) => {
      uploadFile.mutate({ file, parentId: currentFolder.id });
    });
    if (fileInputRef.current) fileInputRef.current.value = "";
  };

  // Files dragged in from the OS (Finder/Explorer) and dropped directly onto
  // a folder card upload straight into that folder, without navigating into it.
  const handleDropFiles = (files: FileList, targetFolderId: string) => {
    Array.from(files).forEach((file) => {
      uploadFile.mutate({ file, parentId: targetFolderId });
    });
  };

  // Bytes come through the authenticated API; a same-origin blob anchor
  // downloads without popups (direct browser access to the object store is
  // unreliable — HSTS upgrades, blocked ports).
  const handleDownload = async (id: string, name: string) => {
    const blob = await fetchDriveFileBlob(id);
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = name;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    URL.revokeObjectURL(url);
  };

  // A card's own drag start becomes a drag of the whole selection when the
  // dragged card is already part of it; otherwise the drag re-targets to
  // just that card (matching most file managers' behavior).
  const handleDragStartItem = (item: DriveItem): string[] => {
    const ids = selectedIds.includes(item.id) ? selectedIds : [item.id];
    setDraggedIds(ids);
    if (!selectedIds.includes(item.id)) {
      setSelectedIds([item.id]);
      setAnchorId(item.id);
    }
    return ids;
  };

  const handleDropOnFolder = (ids: string[], targetFolderId: string) => {
    setDraggedIds(null);
    if (ids.length === 1) {
      moveItem.mutate({ id: ids[0], parentId: targetFolderId });
    } else {
      moveItems.mutate({ ids, parentId: targetFolderId });
    }
    setSelectedIds([]);
  };

  const handleDropOnBreadcrumb = (crumbId: string | null) => {
    setDraggedIds(null);
    setBreadcrumbDropId(null);
    if (!draggedIds || draggedIds.length === 0) return;
    if (crumbId === currentFolder.id) return;
    if (draggedIds.length === 1) {
      moveItem.mutate({ id: draggedIds[0], parentId: crumbId });
    } else {
      moveItems.mutate({ ids: draggedIds, parentId: crumbId });
    }
    setSelectedIds([]);
  };

  const handleBulkDelete = () => {
    if (selectedIds.length === 1) {
      trashItem.mutate(selectedIds[0]);
    } else if (selectedIds.length > 1) {
      trashItems.mutate(selectedIds);
    }
    setSelectedIds([]);
  };

  return (
    <div className="flex h-full gap-5">
      <div className="min-w-0 flex-1 space-y-4">
        <PageHeader
          title="Drive"
          subtitle="Workspace files, folders and agent outputs"
          actions={
            <>
              {selectedIds.length > 1 && !showTrash && (
                <>
                  <span className="text-xs text-text-muted">{selectedIds.length} selected</span>
                  <Button
                    variant="ghost"
                    size="sm"
                    className="bg-surface-raised hover:bg-surface-hover"
                    onClick={() => setShowMoveModal(true)}
                  >
                    <FolderInput size={14} /> Move
                  </Button>
                  <Button
                    variant="danger"
                    size="sm"
                    loading={trashItems.isPending}
                    onClick={handleBulkDelete}
                  >
                    <Trash2 size={14} /> Delete
                  </Button>
                </>
              )}
              <Button variant="secondary" size="sm" onClick={() => setShowNewFolder(true)}>
                <FolderPlus size={14} /> New Folder
              </Button>
              <Button
                size="sm"
                loading={uploadFile.isPending}
                onClick={() => fileInputRef.current?.click()}
              >
                <Upload size={14} /> Upload
              </Button>
              <input
                ref={fileInputRef}
                type="file"
                multiple
                className="hidden"
                onChange={(e) => handleUploadChange(e.target.files)}
              />
            </>
          }
        />

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
                    onDragOver={(e) => {
                      if (!draggedIds || index === crumbs.length - 1) return;
                      e.preventDefault();
                      e.dataTransfer.dropEffect = "move";
                    }}
                    onDragEnter={() => index !== crumbs.length - 1 && setBreadcrumbDropId(crumb.id ?? "root")}
                    onDragLeave={() => setBreadcrumbDropId(null)}
                    onDrop={(e) => {
                      if (!draggedIds || index === crumbs.length - 1) return;
                      e.preventDefault();
                      handleDropOnBreadcrumb(crumb.id);
                    }}
                    className={cn(
                      "mk-chip flex items-center gap-1 rounded-md px-2 py-1",
                      index === crumbs.length - 1
                        ? "mk-chip-active font-semibold"
                        : "text-text-muted hover:bg-surface-hover hover:text-text",
                      breadcrumbDropId === (crumb.id ?? "root") &&
                        "bg-primary-muted/50 text-primary-light ring-2 ring-primary/40",
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
                setSelectedIds([]);
              }}
              className={cn(
                "mk-chip flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-medium",
                showTrash
                  ? "mk-chip-active"
                  : "text-text-muted hover:bg-surface-hover hover:text-text",
              )}
            >
              <Trash2 size={13} /> Trash
            </button>
            <div className="flex rounded-md bg-surface-raised p-0.5">
              <button
                onClick={() => setView("grid")}
                aria-label="Grid view"
                className={cn(
                  "mk-chip rounded p-1.5",
                  view === "grid" ? "mk-chip-active" : "text-text-muted hover:text-text",
                )}
              >
                <LayoutGrid size={14} />
              </button>
              <button
                onClick={() => setView("list")}
                aria-label="List view"
                className={cn(
                  "mk-chip rounded p-1.5",
                  view === "list" ? "mk-chip-active" : "text-text-muted hover:text-text",
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
            {items.map((item, index) => (
              <DriveGridItem
                key={item.id}
                item={item}
                index={index}
                isSelected={selectedIds.includes(item.id)}
                selectionCount={selectedIds.length}
                draggedIds={draggedIds}
                onClick={handleItemClick}
                onDoubleClick={() => !showTrash && openFolder(item)}
                onDragStartItem={handleDragStartItem}
                onDropIds={handleDropOnFolder}
                onDropFiles={handleDropFiles}
                onOpenMove={() => {
                  if (!selectedIds.includes(item.id)) setSelectedIds([item.id]);
                  setShowMoveModal(true);
                }}
                onDownload={(i) => handleDownload(i.id, i.name)}
                onDelete={() => {
                  const ids = selectedIds.includes(item.id) ? selectedIds : [item.id];
                  if (ids.length === 1) trashItem.mutate(ids[0]);
                  else trashItems.mutate(ids);
                  setSelectedIds([]);
                }}
              />
            ))}
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
                      onClick={(e) => {
                        handleItemClick(item, e);
                      }}
                      onDoubleClick={() => !showTrash && openFolder(item)}
                      className={cn(
                        "mk-row cursor-pointer border-b border-border/50 last:border-0",
                        selectedIds.includes(item.id) && "bg-primary-muted/30",
                      )}
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
        onClose={() => setSelectedIds([])}
        title={selected?.kind === "folder" ? "Folder Details" : "File Details"}
      >
        {selected && (
          <div className="space-y-5 px-5 py-4">
            <div className="flex flex-col items-center gap-2 py-3">
              <DriveThumbnail item={selected} size={44} />
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
              <Button
                variant="secondary"
                size="sm"
                className="w-full"
                loading={restoreItem.isPending}
                onClick={() =>
                  restoreItem.mutate(selected.id, { onSuccess: () => setSelectedIds([]) })
                }
              >
                <RotateCcw size={13} /> Restore
              </Button>
            ) : (
              <div className="space-y-2">
                {selected.kind === "file" && (
                  <Button
                    variant="ghost"
                    size="sm"
                    className="w-full bg-surface-raised hover:bg-surface-hover"
                    onClick={() => handleDownload(selected.id, selected.name)}
                  >
                    <Download size={13} /> Download
                  </Button>
                )}
                <Button
                  variant="ghost"
                  size="sm"
                  className="w-full bg-surface-raised hover:bg-surface-hover"
                  onClick={() => setShowMoveModal(true)}
                >
                  <FolderInput size={13} /> Move to…
                </Button>
                <Button
                  variant="danger"
                  size="sm"
                  className="w-full"
                  loading={trashItem.isPending}
                  onClick={() =>
                    trashItem.mutate(selected.id, { onSuccess: () => setSelectedIds([]) })
                  }
                >
                  <Trash2 size={13} /> Move to Trash
                </Button>
              </div>
            )}
          </div>
        )}
      </DetailPanel>
      <NewFolderModal
        open={showNewFolder}
        onOpenChange={setShowNewFolder}
        parentId={currentFolder.id}
      />
      <MoveItemsModal
        open={showMoveModal}
        onOpenChange={(open) => {
          setShowMoveModal(open);
          if (!open) setSelectedIds([]);
        }}
        itemIds={selectedIds}
        currentParentId={currentFolder.id}
      />
    </div>
  );
}
