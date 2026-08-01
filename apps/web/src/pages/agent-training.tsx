import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import { BookOpen, CheckCircle2, Sparkles } from "lucide-react";
import { useAgent, useAgentTraining } from "@/api/hooks";
import type { AgentTrainingSnapshot } from "@/api/types";
import { AgentLevelRing } from "@/components/agents/agent-level-ring";
import { AgentAvatar } from "@/components/agents/agent-avatar";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/cn";
import { joinChannel } from "@/realtime/phoenix-client";
import { useAuthStore } from "@/stores/auth-store";

const MIN_DURATION_MS: Record<string, number> = {
  boost_l3: 4_000,
  boost_l5: 7_000,
  boost_l10: 13_000,
};

export function AgentTrainingPage() {
  const params = useParams({ strict: false }) as { agentId?: string };
  const agentId = params.agentId ?? "";
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const workspaceId = useAuthStore((s) => s.workspaceId);
  const startedAt = useRef(Date.now());
  const [displayLevel, setDisplayLevel] = useState(1);
  const [phase, setPhase] = useState<string>("leveling");
  const [skills, setSkills] = useState<Array<{ name: string; level: number }>>([]);
  const [seededCount, setSeededCount] = useState(0);
  const [skillCount, setSkillCount] = useState(0);
  const [serverComplete, setServerComplete] = useState(false);
  const [minElapsed, setMinElapsed] = useState(false);
  const [levelPulse, setLevelPulse] = useState(false);

  const { data: agentData } = useAgent(agentId);
  const agent = agentData?.data;

  const { data: trainingData } = useAgentTraining(agentId || null);
  const snapshot = trainingData?.data;
  const boostKey = snapshot?.training?.boost_key ?? "boost_l5";
  const targetLevel = snapshot?.target_level ?? snapshot?.training?.target_level ?? 10;
  const minMs = MIN_DURATION_MS[boostKey] ?? 7_000;

  useEffect(() => {
    const t = window.setTimeout(() => setMinElapsed(true), minMs);
    return () => window.clearTimeout(t);
  }, [minMs]);

  useEffect(() => {
    if (!snapshot) return;
    const nextLevel = snapshot.level ?? 1;
    setDisplayLevel((prev) => {
      if (nextLevel > prev) {
        setLevelPulse(true);
        window.setTimeout(() => setLevelPulse(false), 350);
      }
      return Math.max(prev, nextLevel);
    });
    setPhase(snapshot.training?.phase ?? (snapshot.complete ? "complete" : "leveling"));
    if (snapshot.skills?.length) setSkills(snapshot.skills);
    setSeededCount(snapshot.domain_pack?.seeded_count ?? 0);
    setSkillCount(snapshot.domain_pack?.skill_count ?? 0);
    if (snapshot.complete) setServerComplete(true);
  }, [snapshot]);

  // Client-side level tick so the counter feels snappy even between poll ticks.
  useEffect(() => {
    if (serverComplete || displayLevel >= targetLevel) return;
    const tickMs = Math.max(180, Math.floor(minMs / Math.max(targetLevel, 1)));
    const id = window.setInterval(() => {
      setDisplayLevel((prev) => {
        if (prev >= targetLevel) return prev;
        // Don't race ahead of the server by more than 1 level.
        const serverLevel = snapshot?.level ?? 1;
        if (prev >= serverLevel + 1 && !snapshot?.complete) return prev;
        setLevelPulse(true);
        window.setTimeout(() => setLevelPulse(false), 280);
        return prev + 1;
      });
    }, tickMs);
    return () => window.clearInterval(id);
  }, [serverComplete, displayLevel, targetLevel, minMs, snapshot?.level, snapshot?.complete]);

  useEffect(() => {
    if (!workspaceId || !agentId) return;
    const topic = `workspace:${workspaceId}`;
    const channel = joinChannel(topic);
    if (!channel) return;

    const onProgress = (payload: Record<string, unknown>) => {
      if (payload.agent_id !== agentId) return;
      const level = typeof payload.level === "number" ? payload.level : undefined;
      if (level != null) {
        setDisplayLevel((prev) => {
          if (level > prev) {
            setLevelPulse(true);
            window.setTimeout(() => setLevelPulse(false), 350);
          }
          return Math.max(prev, level);
        });
      }
      if (typeof payload.phase === "string") setPhase(payload.phase);
      if (Array.isArray(payload.skills)) {
        setSkills(payload.skills as Array<{ name: string; level: number }>);
      }
      const pack = payload.domain_pack as AgentTrainingSnapshot["domain_pack"] | undefined;
      if (pack) {
        setSeededCount(pack.seeded_count ?? 0);
        setSkillCount(pack.skill_count ?? 0);
      }
      void queryClient.invalidateQueries({ queryKey: ["agents"] });
    };

    const onComplete = (payload: Record<string, unknown>) => {
      if (payload.agent_id !== agentId) return;
      setServerComplete(true);
      setPhase("complete");
      if (typeof payload.level === "number") setDisplayLevel(payload.level);
      if (Array.isArray(payload.skills)) {
        setSkills(payload.skills as Array<{ name: string; level: number }>);
      }
      void queryClient.invalidateQueries({ queryKey: ["agents"] });
      void queryClient.invalidateQueries({ queryKey: ["billing"] });
    };

    const progressRef = channel.on("agent.training_progress", onProgress);
    const completeRef = channel.on("agent.training_complete", onComplete);

    return () => {
      channel.off("agent.training_progress", progressRef);
      channel.off("agent.training_complete", completeRef);
    };
  }, [workspaceId, agentId, queryClient]);

  const ready = serverComplete && minElapsed && displayLevel >= targetLevel;
  const progressPct = Math.min(100, Math.round((displayLevel / Math.max(targetLevel, 1)) * 100));

  useEffect(() => {
    if (ready) return;
    const onBeforeUnload = (e: BeforeUnloadEvent) => {
      e.preventDefault();
      e.returnValue = "";
    };
    window.addEventListener("beforeunload", onBeforeUnload);
    return () => window.removeEventListener("beforeunload", onBeforeUnload);
  }, [ready]);

  const phaseLabel = useMemo(() => {
    if (ready) return "Specialist ready";
    if (phase === "seeding") return "Injecting domain knowledge…";
    if (phase === "complete") return "Finalizing…";
    return "Accelerating learning…";
  }, [phase, ready]);

  const shownSkills = skills.length
    ? skills
    : ((agent?.skills as Array<{ name: string; level: number }>) ?? []);

  return (
    <div className="relative flex h-full min-h-[70vh] items-center justify-center overflow-hidden">
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 opacity-80"
        style={{
          background:
            "radial-gradient(ellipse at 50% 30%, rgba(124,92,255,0.22) 0%, transparent 55%), radial-gradient(ellipse at 70% 80%, rgba(56,189,248,0.12) 0%, transparent 45%)",
        }}
      />

      <div className="relative z-10 mx-auto flex w-full max-w-lg flex-col items-center px-6 py-10 text-center">
        <p className="text-[11px] font-semibold uppercase tracking-[0.18em] text-primary-light">
          Head start training
        </p>
        <h1 className="mt-2 text-2xl font-bold text-text">
          {agent?.display_name ?? snapshot?.display_name ?? "Your agent"}
        </h1>
        <p className="mt-1 text-sm text-text-muted">{phaseLabel}</p>

        <div className="mt-8 flex flex-col items-center gap-4">
          <div
            className={cn(
              "relative transition-transform duration-300",
              levelPulse && "scale-110",
            )}
          >
            {agent ? (
              <AgentLevelRing
                level={displayLevel}
                xp={snapshot?.xp ?? agent.xp ?? 0}
                xpForNext={snapshot?.xp_for_next_level ?? agent.xp_for_next_level ?? 100}
                size="xl"
              >
                <AgentAvatar agent={agent} size="xl" showRing={false} showBadge={false} />
              </AgentLevelRing>
            ) : (
              <div className="flex h-28 w-28 items-center justify-center rounded-full bg-surface-raised text-4xl font-black text-primary">
                {displayLevel}
              </div>
            )}
          </div>

          <div
            key={displayLevel}
            className={cn(
              "font-black tabular-nums text-text",
              "text-6xl tracking-tight",
              levelPulse && "animate-pulse",
            )}
          >
            <span className="text-primary">Lv</span> {displayLevel}
          </div>
          <p className="text-xs text-text-muted">
            Climbing to level {targetLevel}
            {boostKey === "boost_l10" ? " · Specialist pack" : ""}
          </p>
        </div>

        <div className="mt-8 w-full space-y-2">
          <div className="h-2 overflow-hidden rounded-full bg-surface-raised">
            <div
              className="h-full rounded-full bg-gradient-to-r from-primary to-sky-400 transition-all duration-300 ease-out"
              style={{ width: `${progressPct}%` }}
            />
          </div>
          <div className="flex justify-between text-[10px] text-text-muted">
            <span>Level 1</span>
            <span>{progressPct}%</span>
            <span>Level {targetLevel}</span>
          </div>
        </div>

        {shownSkills.length > 0 && (
          <div className="mt-6 grid w-full grid-cols-2 gap-2">
            {shownSkills.slice(0, 4).map((skill) => (
              <div
                key={skill.name}
                className="rounded-xl border border-border bg-surface-raised/50 px-3 py-2 text-left"
              >
                <p className="truncate text-[10px] uppercase tracking-wide text-text-muted">
                  {skill.name}
                </p>
                <p className="mt-0.5 text-sm font-bold tabular-nums text-text">{skill.level}</p>
              </div>
            ))}
          </div>
        )}

        {(boostKey === "boost_l10" || seededCount > 0 || phase === "seeding") && (
          <div className="mt-5 flex w-full items-center gap-3 rounded-xl border border-border bg-surface-raised/40 px-4 py-3 text-left">
            <BookOpen size={18} className="shrink-0 text-primary" />
            <div className="min-w-0 flex-1">
              <p className="text-xs font-semibold text-text">Domain knowledge</p>
              <p className="text-[11px] text-text-muted">
                {seededCount > 0
                  ? `${seededCount} documents loaded${skillCount ? ` · ${skillCount} skills indexed` : ""}`
                  : "Preparing specialist corpus…"}
              </p>
            </div>
            {phase === "seeding" && !ready && (
              <Sparkles size={16} className="shrink-0 animate-pulse text-primary-light" />
            )}
          </div>
        )}

        <div className="mt-8 flex w-full flex-col items-center gap-3">
          {ready ? (
            <>
              <div className="flex items-center gap-2 text-sm font-semibold text-success">
                <CheckCircle2 size={18} />
                Investment unlocked — agent is ready
              </div>
              <Button
                onClick={() => void navigate({ to: "/agents" })}
                data-tour="meet-agent"
              >
                Meet your agent
              </Button>
            </>
          ) : (
            <p className="text-[11px] text-text-muted">
              Stay on this page while {agent?.display_name ?? "your agent"} trains
              {startedAt.current ? "" : ""}…
            </p>
          )}
          {ready && (
            <Link to="/agents" className="text-[11px] text-text-muted underline">
              Back to agents
            </Link>
          )}
        </div>
      </div>
    </div>
  );
}
