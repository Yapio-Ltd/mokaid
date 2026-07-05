import { useMemo, useState } from "react";
import { ChevronLeft, ChevronRight, Plus } from "lucide-react";
import { useCalendarEvents } from "@/api/hooks";
import type { CalendarEvent } from "@/api/types";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { DetailPanel } from "@/components/ui/detail-panel";
import { NewEventModal } from "@/components/modals/new-event-modal";
import { cn } from "@/lib/cn";

type ViewMode = "month" | "week";

const kindColor: Record<string, { dot: string; bg: string }> = {
  meeting: { dot: "bg-primary", bg: "bg-primary-muted" },
  deadline: { dot: "bg-danger", bg: "bg-danger-muted" },
  milestone: { dot: "bg-success", bg: "bg-success-muted" },
  leave: { dot: "bg-warning", bg: "bg-warning-muted" },
  schedule: { dot: "bg-info", bg: "bg-info-muted" },
  event: { dot: "bg-primary", bg: "bg-primary-muted" },
  personal: { dot: "bg-info", bg: "bg-info-muted" },
};

function startOfWeek(date: Date): Date {
  const d = new Date(date);
  d.setDate(d.getDate() - ((d.getDay() + 6) % 7)); // Monday start
  d.setHours(0, 0, 0, 0);
  return d;
}

export function CalendarPage() {
  const [view, setView] = useState<ViewMode>("month");
  const [cursor, setCursor] = useState(() => new Date());
  const [showNewEvent, setShowNewEvent] = useState(false);
  const [selectedEventId, setSelectedEventId] = useState<string | null>(null);

  const { data } = useCalendarEvents();
  const events = data?.data ?? [];
  const selectedEvent = events.find((e) => e.id === selectedEventId) ?? null;

  const eventsByDay = useMemo(() => {
    const map = new Map<string, CalendarEvent[]>();
    events.forEach((event) => {
      const key = new Date(event.start_at).toDateString();
      const list = map.get(key) ?? [];
      list.push(event);
      map.set(key, list);
    });
    return map;
  }, [events]);

  const monthLabel = cursor.toLocaleDateString("en-US", { month: "long", year: "numeric" });

  const days = useMemo(() => {
    if (view === "week") {
      const start = startOfWeek(cursor);
      return Array.from({ length: 7 }, (_, i) => {
        const d = new Date(start);
        d.setDate(start.getDate() + i);
        return d;
      });
    }

    const first = new Date(cursor.getFullYear(), cursor.getMonth(), 1);
    const gridStart = startOfWeek(first);
    return Array.from({ length: 42 }, (_, i) => {
      const d = new Date(gridStart);
      d.setDate(gridStart.getDate() + i);
      return d;
    });
  }, [cursor, view]);

  const navigate = (delta: number) => {
    const next = new Date(cursor);
    if (view === "month") next.setMonth(next.getMonth() + delta);
    else next.setDate(next.getDate() + delta * 7);
    setCursor(next);
  };

  const today = new Date().toDateString();

  return (
    <div className="flex h-full gap-5">
      <div className="flex min-w-0 flex-1 flex-col gap-4">
      <div className="flex items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold text-text">Calendar</h1>
          <p className="text-xs text-text-muted">Deadlines, meetings, schedules and time off</p>
        </div>
        <div className="flex items-center gap-3">
          <div className="flex rounded-md border border-border bg-surface p-0.5">
            {(["month", "week"] as ViewMode[]).map((mode) => (
              <button
                key={mode}
                onClick={() => setView(mode)}
                className={cn(
                  "rounded px-3 py-1.5 text-xs font-medium capitalize transition-colors",
                  view === mode ? "bg-primary-muted text-primary-light" : "text-text-muted hover:text-text",
                )}
              >
                {mode}
              </button>
            ))}
          </div>
          <div className="flex items-center gap-1">
            <Button variant="ghost" size="icon" onClick={() => navigate(-1)} aria-label="Previous">
              <ChevronLeft size={16} />
            </Button>
            <span className="min-w-36 text-center text-sm font-semibold text-text">{monthLabel}</span>
            <Button variant="ghost" size="icon" onClick={() => navigate(1)} aria-label="Next">
              <ChevronRight size={16} />
            </Button>
          </div>
          <Button variant="secondary" size="sm" onClick={() => setCursor(new Date())}>
            Today
          </Button>
          <Button size="sm" onClick={() => setShowNewEvent(true)}>
            <Plus size={14} /> New Event
          </Button>
        </div>
      </div>

      <div className="mk-card flex min-h-0 flex-1 flex-col overflow-hidden">
        <div className="grid grid-cols-7 px-2 pt-3">
          {["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((day) => (
            <div
              key={day}
              className="px-2 pb-2 text-center text-[10px] font-semibold uppercase tracking-[0.14em] text-text-muted"
            >
              {day}
            </div>
          ))}
        </div>
        <div
          className={cn(
            "grid flex-1 grid-cols-7 gap-1 overflow-y-auto px-2 pb-2",
            view === "month" ? "auto-rows-fr" : "grid-rows-1",
          )}
        >
          {days.map((day) => {
            const dayEvents = eventsByDay.get(day.toDateString()) ?? [];
            const inMonth = day.getMonth() === cursor.getMonth();
            const isToday = day.toDateString() === today;

            return (
              <div
                key={day.toISOString()}
                className={cn(
                  "group min-h-24 rounded-md p-1.5 transition-colors duration-150 hover:bg-surface-hover/60",
                  !inMonth && view === "month" && "opacity-45",
                  isToday && "bg-primary-muted/40 ring-1 ring-inset ring-primary/25",
                )}
              >
                <span
                  className={cn(
                    "mb-1 inline-flex h-6 w-6 items-center justify-center rounded-full text-[11px] font-medium transition-colors",
                    isToday ? "bg-primary text-white" : inMonth ? "text-text" : "text-text-disabled",
                  )}
                >
                  {day.getDate()}
                </span>
                <div className="space-y-1">
                  {dayEvents.slice(0, view === "week" ? 10 : 3).map((event) => {
                    const colors = kindColor[event.kind] ?? kindColor.event;
                    return (
                      <button
                        key={event.id}
                        type="button"
                        title={event.title}
                        onClick={() => setSelectedEventId(event.id)}
                        className={cn(
                          "flex w-full items-center gap-1.5 truncate rounded-full px-2 py-0.5 text-left text-[10px] font-medium text-text transition-transform duration-150 hover:scale-[1.02]",
                          colors.bg,
                        )}
                      >
                        <span className={cn("h-1.5 w-1.5 shrink-0 rounded-full", colors.dot)} />
                        {!event.all_day && (
                          <span className="shrink-0 text-text-muted">
                            {new Date(event.start_at).toLocaleTimeString("en-US", {
                              hour: "numeric",
                              minute: "2-digit",
                            })}
                          </span>
                        )}
                        <span className="truncate">{event.title}</span>
                      </button>
                    );
                  })}
                  {dayEvents.length > 3 && view === "month" && (
                    <p className="px-2 text-[10px] text-text-muted">+{dayEvents.length - 3} more</p>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-3 text-[11px] text-text-muted">
        <span className="font-medium">Legend:</span>
        <Badge tone="primary">Meeting</Badge>
        <Badge tone="danger">Deadline</Badge>
        <Badge tone="success">Milestone</Badge>
        <Badge tone="warning">Time off</Badge>
        <Badge tone="info">Schedule</Badge>
      </div>
      </div>

      <DetailPanel
        open={selectedEvent != null}
        onClose={() => setSelectedEventId(null)}
        title="Event Details"
      >
        {selectedEvent && (
          <div className="space-y-5 px-5 py-4">
            <div>
              <h3 className="text-sm font-bold text-text">{selectedEvent.title}</h3>
              <div className="mt-2 flex flex-wrap gap-2">
                <Badge tone="primary" className="capitalize">
                  {selectedEvent.kind}
                </Badge>
                {selectedEvent.all_day && <Badge tone="muted">All day</Badge>}
              </div>
            </div>
            {selectedEvent.description && (
              <p className="text-xs leading-relaxed text-text-secondary">
                {selectedEvent.description}
              </p>
            )}
            <div className="space-y-1.5 text-xs">
              <div className="flex justify-between">
                <span className="text-text-muted">Starts</span>
                <span className="text-text">
                  {new Date(selectedEvent.start_at).toLocaleString("en-US", {
                    dateStyle: "medium",
                    timeStyle: selectedEvent.all_day ? undefined : "short",
                  })}
                </span>
              </div>
              {selectedEvent.end_at && (
                <div className="flex justify-between">
                  <span className="text-text-muted">Ends</span>
                  <span className="text-text">
                    {new Date(selectedEvent.end_at).toLocaleString("en-US", {
                      dateStyle: "medium",
                      timeStyle: selectedEvent.all_day ? undefined : "short",
                    })}
                  </span>
                </div>
              )}
              {selectedEvent.project_name && (
                <div className="flex justify-between">
                  <span className="text-text-muted">Project</span>
                  <span className="text-text">{selectedEvent.project_name}</span>
                </div>
              )}
              {selectedEvent.member_name && (
                <div className="flex justify-between">
                  <span className="text-text-muted">Member</span>
                  <span className="text-text">{selectedEvent.member_name}</span>
                </div>
              )}
              {selectedEvent.agent_name && (
                <div className="flex justify-between">
                  <span className="text-text-muted">Agent</span>
                  <span className="text-text">{selectedEvent.agent_name}</span>
                </div>
              )}
              {selectedEvent.task_title && (
                <div className="flex justify-between">
                  <span className="text-text-muted">Task</span>
                  <span className="text-text">{selectedEvent.task_title}</span>
                </div>
              )}
            </div>
          </div>
        )}
      </DetailPanel>

      <NewEventModal open={showNewEvent} onOpenChange={setShowNewEvent} defaultDate={cursor} />
    </div>
  );
}
