import { useState } from "react";
import { CalendarClock, Pause, Play, Sparkles, Trash2, Wand2 } from "lucide-react";
import type { Agent, ScheduleDraft } from "@/api/types";
import {
  useAgentSchedules,
  useCreateAgentSchedule,
  useDeleteAgentSchedule,
  useParseAgentSchedule,
  useUpdateAgentSchedule,
} from "@/api/hooks";
import { ApiError } from "@/api/client";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { formatRelative } from "@/lib/format";
import { cn } from "@/lib/cn";
import { toast } from "@/stores/toast-store";

/** Human-ish cron description for common patterns; falls back to the raw cron. */
function describeCron(cron: string): string {
  const parts = cron.trim().split(/\s+/);
  if (parts.length !== 5) return cron;
  const [min, hour, dom, , dow] = parts;
  const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  const time =
    /^\d+$/.test(hour) && /^\d+$/.test(min)
      ? `${hour.padStart(2, "0")}:${min.padStart(2, "0")}`
      : null;

  if (time && dom === "*" && dow === "*") return `Every day at ${time}`;
  if (time && dom === "*" && /^\d$/.test(dow)) return `Every ${days[Number(dow)]} at ${time}`;
  if (time && /^\d+$/.test(dom) && dow === "*") return `Monthly on day ${dom} at ${time}`;
  if (min.startsWith("*/") && hour === "*") return `Every ${min.slice(2)} minutes`;
  return cron;
}

/** "Automations" tab: recurring missions the agent runs on its own. */
export function AutomationsSection({ agent }: { agent: Agent }) {
  const { data } = useAgentSchedules(agent.id);
  const createSchedule = useCreateAgentSchedule();
  const updateSchedule = useUpdateAgentSchedule();
  const deleteSchedule = useDeleteAgentSchedule();
  const parseSchedule = useParseAgentSchedule();

  const [text, setText] = useState("");
  const [draft, setDraft] = useState<ScheduleDraft | null>(null);

  const schedules = data?.data ?? [];

  const generate = () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    parseSchedule.mutate(
      { agentId: agent.id, text: trimmed },
      {
        onSuccess: (result) => setDraft(result.data),
        onError: (error) =>
          toast({
            tone: "error",
            title: "Could not understand the schedule",
            description:
              error instanceof ApiError
                ? error.message
                : "Try describing it differently (e.g. “every Monday at 9am, prepare the weekly report”).",
          }),
      },
    );
  };

  const confirmDraft = () => {
    if (!draft) return;
    createSchedule.mutate(
      {
        agentId: agent.id,
        name: draft.name,
        cron_expression: draft.cron_expression,
        timezone: draft.timezone,
        prompt: draft.prompt,
      },
      {
        onSuccess: () => {
          setDraft(null);
          setText("");
          toast({
            tone: "success",
            title: "Automation created",
            description: `${agent.display_name} will now work on “${draft.name}” on schedule.`,
          });
        },
        onError: (error) =>
          toast({
            tone: "error",
            title: "Could not create automation",
            description: error instanceof ApiError ? error.message : "Something went wrong.",
          }),
      },
    );
  };

  return (
    <div className="space-y-5">
      <div>
        <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
          Automations
        </p>
        <p className="text-[11px] leading-relaxed text-text-muted">
          Recurring missions {agent.display_name.split(" ")[0]} runs without being
          asked — results land in your chat like any other mission, approvals
          included.
        </p>
      </div>

      {/* Natural-language creation */}
      <div className="space-y-2 rounded-xl border border-border/60 bg-surface-raised/40 p-3.5">
        <div className="flex items-start gap-2">
          <Wand2 size={13} className="mt-0.5 shrink-0 text-primary-light" />
          <p className="text-[11px] leading-relaxed text-text-secondary">
            Describe it naturally — “every Monday at 9am, prepare the weekly
            report”, “chaque vendredi 17h, fais le bilan de la semaine”.
          </p>
        </div>
        <textarea
          value={text}
          onChange={(e) => setText(e.target.value)}
          rows={2}
          placeholder="Every Monday at 9am, prepare the weekly report…"
          className="mk-input min-h-[56px] resize-y py-2 text-[12px] leading-relaxed"
          aria-label="Automation description"
        />
        <div className="flex justify-end">
          <Button
            size="sm"
            disabled={!text.trim() || parseSchedule.isPending}
            loading={parseSchedule.isPending}
            onClick={generate}
          >
            <Sparkles size={12} /> Generate schedule
          </Button>
        </div>
      </div>

      {/* Parsed draft — editable before confirming */}
      {draft && (
        <div className="space-y-2.5 rounded-xl border border-primary/40 bg-primary-muted/20 p-3.5">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-primary-light">
            Review the automation
          </p>
          <label className="block space-y-1">
            <span className="text-[10px] font-medium text-text-muted">Name</span>
            <input
              value={draft.name}
              onChange={(e) => setDraft({ ...draft, name: e.target.value })}
              className="mk-input h-8 text-[12px]"
            />
          </label>
          <div className="grid grid-cols-2 gap-2">
            <label className="block space-y-1">
              <span className="text-[10px] font-medium text-text-muted">Cron</span>
              <input
                value={draft.cron_expression}
                onChange={(e) => setDraft({ ...draft, cron_expression: e.target.value })}
                className="mk-input h-8 font-mono text-[11px]"
              />
            </label>
            <label className="block space-y-1">
              <span className="text-[10px] font-medium text-text-muted">UTC offset</span>
              <input
                value={draft.timezone}
                onChange={(e) => setDraft({ ...draft, timezone: e.target.value })}
                placeholder="+02:00"
                className="mk-input h-8 font-mono text-[11px]"
              />
            </label>
          </div>
          <p className="text-[11px] text-text-secondary">
            {draft.human_readable || describeCron(draft.cron_expression)}
          </p>
          <label className="block space-y-1">
            <span className="text-[10px] font-medium text-text-muted">Mission brief</span>
            <textarea
              value={draft.prompt}
              onChange={(e) => setDraft({ ...draft, prompt: e.target.value })}
              rows={3}
              className="mk-input min-h-[70px] resize-y py-2 text-[12px] leading-relaxed"
            />
          </label>
          <div className="flex justify-end gap-2">
            <Button size="sm" variant="ghost" onClick={() => setDraft(null)}>
              Discard
            </Button>
            <Button
              size="sm"
              loading={createSchedule.isPending}
              disabled={!draft.name.trim() || !draft.prompt.trim()}
              onClick={confirmDraft}
            >
              Create automation
            </Button>
          </div>
        </div>
      )}

      {/* Existing automations */}
      {schedules.length > 0 ? (
        <div className="space-y-2">
          {schedules.map((schedule) => (
            <div
              key={schedule.id}
              className={cn(
                "space-y-1.5 rounded-xl border p-3.5",
                schedule.enabled
                  ? "border-border/60 bg-surface-raised/40"
                  : "border-border/40 bg-surface-raised/20 opacity-70",
              )}
            >
              <div className="flex items-center gap-2">
                <CalendarClock size={13} className="shrink-0 text-primary-light" />
                <p className="min-w-0 flex-1 truncate text-xs font-semibold text-text">
                  {schedule.name}
                </p>
                <Badge tone={schedule.enabled ? "success" : "muted"}>
                  {schedule.enabled ? "Active" : "Paused"}
                </Badge>
              </div>
              <p className="text-[11px] text-text-secondary">
                {describeCron(schedule.cron_expression)}
                {schedule.timezone && schedule.timezone !== "+00:00" && schedule.timezone !== "Etc/UTC"
                  ? ` (UTC${schedule.timezone})`
                  : ""}
              </p>
              <p className="line-clamp-2 text-[11px] leading-relaxed text-text-muted">
                {schedule.prompt}
              </p>
              <div className="flex items-center justify-between pt-0.5">
                <span className="text-[10px] text-text-muted">
                  {schedule.runs_count > 0
                    ? `Ran ${schedule.runs_count}× · last ${formatRelative(schedule.last_run_at)}`
                    : "Never ran yet"}
                </span>
                <div className="flex items-center gap-1">
                  <button
                    type="button"
                    aria-label={schedule.enabled ? "Pause automation" : "Resume automation"}
                    disabled={updateSchedule.isPending}
                    onClick={() =>
                      updateSchedule.mutate({
                        agentId: agent.id,
                        scheduleId: schedule.id,
                        enabled: !schedule.enabled,
                      })
                    }
                    className="rounded p-1.5 text-text-muted transition-colors hover:bg-surface-hover hover:text-text"
                  >
                    {schedule.enabled ? <Pause size={12} /> : <Play size={12} />}
                  </button>
                  <button
                    type="button"
                    aria-label="Delete automation"
                    disabled={deleteSchedule.isPending}
                    onClick={() => {
                      if (!window.confirm(`Delete automation "${schedule.name}"?`)) return;
                      deleteSchedule.mutate({ agentId: agent.id, scheduleId: schedule.id });
                    }}
                    className="rounded p-1.5 text-text-muted transition-colors hover:bg-surface-hover hover:text-danger"
                  >
                    <Trash2 size={12} />
                  </button>
                </div>
              </div>
            </div>
          ))}
        </div>
      ) : (
        !draft && (
          <p className="rounded-xl bg-surface-raised/30 px-4 py-6 text-center text-[11px] text-text-muted">
            No automations yet — describe one above and your employee will start
            working on its own schedule.
          </p>
        )
      )}
    </div>
  );
}
