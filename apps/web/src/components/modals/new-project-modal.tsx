import { useState } from "react";
import { useCreateProject } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/cn";

interface NewProjectModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: (projectId: string) => void;
}

const priorityOptions = [
  { value: "low", label: "Low" },
  { value: "medium", label: "Medium" },
  { value: "high", label: "High" },
  { value: "urgent", label: "Urgent" },
];

const covers: Array<{ kind: string; gradient: string; label: string }> = [
  { kind: "meeting", gradient: "from-[#5936d1] to-[#8f72ff]", label: "Violet" },
  { kind: "coding", gradient: "from-[#1d4ed8] to-[#60a5fa]", label: "Blue" },
  { kind: "design", gradient: "from-[#be185d] to-[#f472b6]", label: "Pink" },
  { kind: "whiteboard", gradient: "from-[#047857] to-[#34d399]", label: "Green" },
  { kind: "office", gradient: "from-[#b45309] to-[#fbbf24]", label: "Amber" },
];

export function NewProjectModal({ open, onOpenChange, onCreated }: NewProjectModalProps) {
  const createProject = useCreateProject();

  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [priority, setPriority] = useState("medium");
  const [dueAt, setDueAt] = useState("");
  const [cover, setCover] = useState("meeting");

  const reset = () => {
    setName("");
    setDescription("");
    setPriority("medium");
    setDueAt("");
    setCover("meeting");
  };

  const handleSubmit = async () => {
    if (!name.trim()) return;
    const created = await createProject.mutateAsync({
      name: name.trim(),
      description: description.trim() || undefined,
      priority: priority as never,
      status: "active" as never,
      cover_kind: cover,
      due_at: dueAt ? new Date(dueAt).toISOString() : undefined,
    });
    reset();
    onOpenChange(false);
    onCreated?.(created.data.id);
  };

  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title="New Project"
      description="A project groups tasks, agents and files around one goal."
      footer={
        <>
          <Button variant="ghost" size="sm" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            size="sm"
            loading={createProject.isPending}
            disabled={!name.trim()}
            onClick={handleSubmit}
          >
            Create Project
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <Field label="Name" required>
          <input
            className="mk-input"
            placeholder="e.g. Website Redesign"
            value={name}
            onChange={(e) => setName(e.target.value)}
            autoFocus
          />
        </Field>
        <Field label="Description">
          <Textarea
            placeholder="What is this project about?"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
        </Field>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Priority">
            <Select value={priority} onValueChange={setPriority} options={priorityOptions} />
          </Field>
          <Field label="Due date">
            <input
              type="date"
              className="mk-input"
              value={dueAt}
              onChange={(e) => setDueAt(e.target.value)}
            />
          </Field>
        </div>
        <Field label="Cover">
          <div className="flex gap-2">
            {covers.map((c) => (
              <button
                key={c.kind}
                type="button"
                onClick={() => setCover(c.kind)}
                aria-label={c.label}
                className={cn(
                  "h-9 w-14 rounded-md bg-gradient-to-br transition-transform",
                  c.gradient,
                  cover === c.kind &&
                    "scale-105 ring-2 ring-white/70 ring-offset-2 ring-offset-surface",
                )}
              />
            ))}
          </div>
        </Field>
      </div>
    </Dialog>
  );
}
