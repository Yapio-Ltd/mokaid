import { useState } from "react";
import { useCreateCalendarEvent, useProjects } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";

interface NewEventModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  defaultDate?: Date;
}

const kindOptions = [
  { value: "meeting", label: "Meeting" },
  { value: "deadline", label: "Deadline" },
  { value: "milestone", label: "Milestone" },
  { value: "personal", label: "Personal" },
  { value: "event", label: "Other" },
];

function toLocalInputValue(date: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export function NewEventModal({ open, onOpenChange, defaultDate }: NewEventModalProps) {
  const createEvent = useCreateCalendarEvent();
  const { data: projectsData } = useProjects();

  const initial = defaultDate ?? new Date();
  const [title, setTitle] = useState("");
  const [kind, setKind] = useState("meeting");
  const [description, setDescription] = useState("");
  const [startAt, setStartAt] = useState(toLocalInputValue(initial));
  const [endAt, setEndAt] = useState("");
  const [allDay, setAllDay] = useState(false);
  const [projectId, setProjectId] = useState<string | undefined>();

  const projects = projectsData?.data ?? [];

  const reset = () => {
    setTitle("");
    setKind("meeting");
    setDescription("");
    setStartAt(toLocalInputValue(new Date()));
    setEndAt("");
    setAllDay(false);
    setProjectId(undefined);
  };

  const handleSubmit = async () => {
    if (!title.trim() || !startAt) return;
    await createEvent.mutateAsync({
      title: title.trim(),
      kind,
      description: description.trim() || undefined,
      start_at: new Date(startAt).toISOString(),
      end_at: endAt ? new Date(endAt).toISOString() : undefined,
      all_day: allDay,
      project_id: projectId,
    });
    reset();
    onOpenChange(false);
  };

  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title="New Event"
      footer={
        <>
          <Button variant="ghost" size="sm" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            size="sm"
            loading={createEvent.isPending}
            disabled={!title.trim() || !startAt}
            onClick={handleSubmit}
          >
            Create Event
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <Field label="Title" required>
          <input
            className="mk-input"
            placeholder="e.g. Sprint review"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            autoFocus
          />
        </Field>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Type">
            <Select value={kind} onValueChange={setKind} options={kindOptions} />
          </Field>
          <Field label="Project">
            <Select
              value={projectId}
              onValueChange={setProjectId}
              placeholder="None"
              options={projects.map((p) => ({ value: p.id, label: p.name }))}
            />
          </Field>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Starts" required>
            <input
              type="datetime-local"
              className="mk-input"
              value={startAt}
              onChange={(e) => setStartAt(e.target.value)}
            />
          </Field>
          <Field label="Ends">
            <input
              type="datetime-local"
              className="mk-input"
              value={endAt}
              onChange={(e) => setEndAt(e.target.value)}
            />
          </Field>
        </div>
        <label className="flex cursor-pointer items-center gap-2 text-xs text-text-secondary">
          <input
            type="checkbox"
            checked={allDay}
            onChange={(e) => setAllDay(e.target.checked)}
            className="h-3.5 w-3.5 accent-[var(--mk-primary-500)]"
          />
          All-day event
        </label>
        <Field label="Notes">
          <Textarea
            className="min-h-[64px]"
            placeholder="Optional details…"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
        </Field>
      </div>
    </Dialog>
  );
}
