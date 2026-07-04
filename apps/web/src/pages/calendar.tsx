import { useMemo, useState } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { useCalendarEvents } from "@/api/hooks";
import type { CalendarEvent } from "@/api/types";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/cn";

type ViewMode = "month" | "week";

const kindColor: Record<string, string> = {
  meeting: "border-l-primary bg-primary-muted",
  deadline: "border-l-danger bg-danger-muted",
  milestone: "border-l-success bg-success-muted",
  leave: "border-l-warning bg-warning-muted",
  schedule: "border-l-info bg-info-muted",
  event: "border-l-primary bg-primary-muted",
  personal: "border-l-info bg-info-muted",
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

  const { data } = useCalendarEvents();
  const events = data?.data ?? [];

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
    <div className="flex h-full flex-col gap-4">
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
        </div>
      </div>

      <div className="mk-card flex min-h-0 flex-1 flex-col overflow-hidden">
        <div className="grid grid-cols-7 border-b border-border">
          {["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((day) => (
            <div key={day} className="px-2 py-2 text-center text-[11px] font-semibold uppercase tracking-wide text-text-muted">
              {day}
            </div>
          ))}
        </div>
        <div
          className={cn(
            "grid flex-1 grid-cols-7 overflow-y-auto",
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
                  "min-h-24 border-b border-r border-border/50 p-1.5",
                  !inMonth && view === "month" && "bg-bg-deep/50",
                )}
              >
                <span
                  className={cn(
                    "mb-1 inline-flex h-6 w-6 items-center justify-center rounded-full text-[11px] font-medium",
                    isToday ? "bg-primary text-white" : inMonth ? "text-text" : "text-text-disabled",
                  )}
                >
                  {day.getDate()}
                </span>
                <div className="space-y-1">
                  {dayEvents.slice(0, view === "week" ? 10 : 3).map((event) => (
                    <div
                      key={event.id}
                      title={event.title}
                      className={cn(
                        "truncate rounded border-l-2 px-1.5 py-0.5 text-[10px] font-medium text-text",
                        kindColor[event.kind] ?? kindColor.event,
                      )}
                    >
                      {!event.all_day && (
                        <span className="mr-1 text-text-muted">
                          {new Date(event.start_at).toLocaleTimeString("en-US", {
                            hour: "numeric",
                            minute: "2-digit",
                          })}
                        </span>
                      )}
                      {event.title}
                    </div>
                  ))}
                  {dayEvents.length > 3 && view === "month" && (
                    <p className="px-1 text-[10px] text-text-muted">+{dayEvents.length - 3} more</p>
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
  );
}
