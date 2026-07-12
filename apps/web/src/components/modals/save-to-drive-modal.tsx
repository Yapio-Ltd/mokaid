import { useState } from "react";
import { ChevronRight, Folder, FolderPlus, Home } from "lucide-react";
import { useCreateFolder, useDriveItems, useMoveDriveItems } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { cn } from "@/lib/cn";
import { toast } from "@/stores/toast-store";

interface DriveCrumb {
  id: string | null;
  name: string;
}

/**
 * Pick a Drive folder and move one or more deliverables there. Includes inline
 * folder creation so the user can organize outputs without leaving the flow.
 */
export function SaveToDriveModal({
  open,
  onOpenChange,
  itemIds,
  itemLabel,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  itemIds: string[];
  itemLabel?: string;
}) {
  const [crumbs, setCrumbs] = useState<DriveCrumb[]>([{ id: null, name: "Drive" }]);
  const [newFolderName, setNewFolderName] = useState("");
  const destination = crumbs[crumbs.length - 1];
  const { data, isLoading } = useDriveItems(destination.id);
  const moveItems = useMoveDriveItems();
  const createFolder = useCreateFolder();

  const folders = (data?.data ?? []).filter(
    (item) => item.kind === "folder" && !itemIds.includes(item.id),
  );

  const reset = () => {
    setCrumbs([{ id: null, name: "Drive" }]);
    setNewFolderName("");
  };

  const handleClose = (next: boolean) => {
    if (!next) reset();
    onOpenChange(next);
  };

  const handleSave = async () => {
    await moveItems.mutateAsync({ ids: itemIds, parentId: destination.id });
    toast({
      tone: "success",
      title: "Saved to Drive",
      description:
        itemIds.length > 1
          ? `${itemIds.length} files moved to ${destination.name}.`
          : `${itemLabel ?? "File"} saved to ${destination.name}.`,
    });
    handleClose(false);
  };

  const handleCreateFolder = async () => {
    const name = newFolderName.trim();
    if (!name) return;
    const result = await createFolder.mutateAsync({ name, parent_id: destination.id });
    setNewFolderName("");
    setCrumbs((prev) => [...prev, { id: result.data.id, name: result.data.name }]);
  };

  return (
    <Dialog
      open={open}
      onOpenChange={handleClose}
      title="Save to Drive"
      description={
        itemIds.length > 1
          ? `Choose a folder for ${itemIds.length} files.`
          : `Choose a folder for ${itemLabel ?? "this file"}.`
      }
      footer={
        <>
          <Button variant="ghost" size="sm" onClick={() => handleClose(false)}>
            Cancel
          </Button>
          <Button size="sm" loading={moveItems.isPending} onClick={handleSave}>
            Save here
          </Button>
        </>
      }
    >
      <nav className="mb-3 flex min-w-0 flex-wrap items-center gap-1 text-xs" aria-label="Breadcrumb">
        {crumbs.map((crumb, index) => (
          <span key={crumb.id ?? "root"} className="flex items-center gap-1">
            {index > 0 && <ChevronRight size={12} className="text-text-muted" />}
            <button
              type="button"
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
        ))}
      </nav>

      <div className="mb-3 flex gap-2">
        <input
          type="text"
          value={newFolderName}
          onChange={(e) => setNewFolderName(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && void handleCreateFolder()}
          placeholder="New folder name…"
          className="mk-input h-8 flex-1 text-xs"
        />
        <Button
          size="sm"
          variant="secondary"
          loading={createFolder.isPending}
          disabled={!newFolderName.trim()}
          onClick={() => void handleCreateFolder()}
          className="shrink-0 gap-1"
        >
          <FolderPlus size={13} />
          Create
        </Button>
      </div>

      <div className="max-h-56 overflow-y-auto rounded-md border border-border">
        {isLoading ? (
          <p className="px-3 py-4 text-center text-xs text-text-muted">Loading folders…</p>
        ) : folders.length === 0 ? (
          <p className="px-3 py-4 text-center text-xs text-text-muted">
            No subfolders — save here or create one above.
          </p>
        ) : (
          folders.map((folder) => (
            <button
              key={folder.id}
              type="button"
              onClick={() => setCrumbs((prev) => [...prev, { id: folder.id, name: folder.name }])}
              className="flex w-full items-center gap-2 px-3 py-2 text-left text-xs text-text transition-colors last:rounded-b-md first:rounded-t-md hover:bg-surface-hover"
            >
              <Folder size={14} className="text-primary-light" fill="currentColor" fillOpacity={0.2} />
              {folder.name}
            </button>
          ))
        )}
      </div>
    </Dialog>
  );
}
