import { useState } from "react";
import { useCreateFolder } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";

interface NewFolderModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  parentId: string | null;
}

export function NewFolderModal({ open, onOpenChange, parentId }: NewFolderModalProps) {
  const createFolder = useCreateFolder();
  const [name, setName] = useState("");

  const handleSubmit = async () => {
    if (!name.trim()) return;
    await createFolder.mutateAsync({ name: name.trim(), parent_id: parentId });
    setName("");
    onOpenChange(false);
  };

  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title="New Folder"
      footer={
        <>
          <Button variant="ghost" size="sm" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            size="sm"
            loading={createFolder.isPending}
            disabled={!name.trim()}
            onClick={handleSubmit}
          >
            Create Folder
          </Button>
        </>
      }
    >
      <Field label="Folder name" required>
        <input
          className="mk-input"
          placeholder="e.g. Campaign assets"
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && handleSubmit()}
          autoFocus
        />
      </Field>
    </Dialog>
  );
}
