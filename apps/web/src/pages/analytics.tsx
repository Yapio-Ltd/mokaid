import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  Legend,
  Line,
  LineChart,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { CheckCircle2, Clock, TrendingUp, Users } from "lucide-react";
import { chartPalette, colors } from "@mokaid/design-tokens";
import { useAnalyticsOverview } from "@/api/hooks";
import { Card, CardBody, CardHeader, CardTitle } from "@/components/ui/card";
import { KpiCard } from "@/components/ui/kpi-card";
import { PageHeader } from "@/components/ui/page-header";
import { Avatar } from "@/components/ui/avatar";
import { SkeletonRows } from "@/components/ui/skeleton";
import { ProgressBar } from "@/components/ui/progress-bar";

const tooltipStyle = {
  backgroundColor: colors.surfaceOverlay,
  border: `1px solid ${colors.border}`,
  borderRadius: 8,
  fontSize: 12,
  color: colors.text,
  boxShadow: "0 0 18px rgba(124, 92, 255, 0.14), 0 8px 24px rgba(0, 0, 0, 0.4)",
};

/* Violet family — brighter/deeper for higher priority */
const priorityColors: Record<string, string> = {
  urgent: "#6f4cff",
  high: "#8f72ff",
  medium: "#ab95ff",
  low: "#c8b9ff",
};

/* AI = light violet, Human-linked = deep violet, Hybrid = mid */
const splitColors: Record<string, string> = {
  "AI Agents": "#c8b9ff",
  "Human-linked": "#6f4cff",
  Hybrid: "#8f72ff",
};

export function AnalyticsPage() {
  const { data, isLoading } = useAnalyticsOverview();

  if (isLoading || !data) {
    return (
      <div className="space-y-5">
        <PageHeader title="Analytics" />
        <SkeletonRows rows={6} />
      </div>
    );
  }

  const { overview, tasks_by_status, tasks_by_priority, tasks_completed_daily, top_agents, agent_task_split } =
    data.data;

  const dailySeries = tasks_completed_daily.map((d) => ({
    day: new Date(d.day).toLocaleDateString("en-US", { month: "short", day: "numeric" }),
    completed: d.count,
  }));

  const statusSeries = tasks_by_status.map((s) => ({
    name: s.status.replace("_", " "),
    value: s.count,
  }));

  const prioritySeries = tasks_by_priority.map((p) => ({
    name: p.priority,
    value: p.count,
  }));

  const splitSeries = agent_task_split.map((s) => ({
    name: s.kind === "ai" ? "AI Agents" : s.kind === "human_linked" ? "Human-linked" : "Hybrid",
    value: s.count,
  }));

  return (
    <div className="space-y-5">
      <PageHeader title="Analytics" subtitle="Workspace performance over the last 30 days" />

      <div className="grid grid-cols-2 gap-4 xl:grid-cols-4">
        <KpiCard
          label="Completion Rate"
          value={`${overview.completion_rate}%`}
          icon={<TrendingUp size={20} />}
          tone="primary"
        />
        <KpiCard
          label="Tasks Completed"
          value={overview.completed_tasks}
          icon={<CheckCircle2 size={20} />}
          tone="success"
        />
        <KpiCard
          label="Avg. Completion Time"
          value={`${overview.avg_task_hours}h`}
          icon={<Clock size={20} />}
          tone="info"
        />
        <KpiCard
          label="Active Agents"
          value={overview.active_agents}
          icon={<Users size={20} />}
          tone="warning"
        />
      </div>

      <div className="grid gap-5 xl:grid-cols-2">
        <Card className="mk-fade-up">
          <CardHeader>
            <CardTitle>Tasks Completed Over Time</CardTitle>
          </CardHeader>
          <CardBody className="h-64">
            <ResponsiveContainer width="100%" height="100%">
              <LineChart data={dailySeries}>
                <CartesianGrid stroke={colors.border} strokeDasharray="3 3" vertical={false} />
                <XAxis dataKey="day" stroke={colors.textMuted} fontSize={11} tickLine={false} />
                <YAxis stroke={colors.textMuted} fontSize={11} tickLine={false} axisLine={false} />
                <Tooltip contentStyle={tooltipStyle} />
                <Line
                  type="monotone"
                  dataKey="completed"
                  stroke={colors.primary}
                  strokeWidth={2}
                  dot={{ fill: colors.primary, r: 3 }}
                />
              </LineChart>
            </ResponsiveContainer>
          </CardBody>
        </Card>

        <Card className="mk-fade-up" style={{ animationDelay: "60ms" }}>
          <CardHeader>
            <CardTitle>Tasks by Status</CardTitle>
          </CardHeader>
          <CardBody className="h-64">
            <ResponsiveContainer width="100%" height="100%">
              <PieChart>
                <Pie
                  data={statusSeries}
                  dataKey="value"
                  nameKey="name"
                  innerRadius={55}
                  outerRadius={85}
                  paddingAngle={3}
                >
                  {statusSeries.map((_, index) => (
                    <Cell key={index} fill={chartPalette[index % chartPalette.length]} stroke="none" />
                  ))}
                </Pie>
                <Tooltip contentStyle={tooltipStyle} />
                <Legend
                  formatter={(value: string) => (
                    <span style={{ color: colors.textSecondary, fontSize: 11 }}>{value}</span>
                  )}
                />
              </PieChart>
            </ResponsiveContainer>
          </CardBody>
        </Card>

        <Card className="mk-fade-up" style={{ animationDelay: "120ms" }}>
          <CardHeader>
            <CardTitle>Tasks by Priority</CardTitle>
          </CardHeader>
          <CardBody className="h-64">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={prioritySeries}>
                <CartesianGrid stroke={colors.border} strokeDasharray="3 3" vertical={false} />
                <XAxis dataKey="name" stroke={colors.textMuted} fontSize={11} tickLine={false} />
                <YAxis stroke={colors.textMuted} fontSize={11} tickLine={false} axisLine={false} />
                <Tooltip contentStyle={tooltipStyle} cursor={{ fill: "rgba(124,92,255,0.06)" }} />
                <Bar dataKey="value" radius={[6, 6, 0, 0]}>
                  {prioritySeries.map((entry, index) => (
                    <Cell key={index} fill={priorityColors[entry.name] ?? "#8f72ff"} />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </CardBody>
        </Card>

        <Card className="mk-fade-up" style={{ animationDelay: "180ms" }}>
          <CardHeader>
            <CardTitle>AI vs Human Output</CardTitle>
          </CardHeader>
          <CardBody className="h-64">
            <ResponsiveContainer width="100%" height="100%">
              <PieChart>
                <Pie data={splitSeries} dataKey="value" nameKey="name" outerRadius={85}>
                  {splitSeries.map((entry, index) => (
                    <Cell key={index} fill={splitColors[entry.name] ?? "#8f72ff"} stroke="none" />
                  ))}
                </Pie>
                <Tooltip contentStyle={tooltipStyle} />
                <Legend
                  formatter={(value: string) => (
                    <span style={{ color: colors.textSecondary, fontSize: 11 }}>{value}</span>
                  )}
                />
              </PieChart>
            </ResponsiveContainer>
          </CardBody>
        </Card>
      </div>

      <Card className="mk-fade-up" style={{ animationDelay: "240ms" }}>
        <CardHeader>
          <CardTitle>Top Performing Agents</CardTitle>
        </CardHeader>
        <CardBody className="space-y-3">
          {top_agents.map((agent, index) => (
            <div key={agent.agent_id} className="flex items-center gap-3">
              <span className="w-5 text-center text-xs font-bold text-text-muted">{index + 1}</span>
              <Avatar name={agent.display_name} size="sm" isAi={agent.kind === "ai"} />
              <div className="min-w-0 flex-1">
                <p className="truncate text-xs font-semibold text-text">{agent.display_name}</p>
                <p className="text-[11px] text-text-muted">{agent.role_title}</p>
              </div>
              <div className="w-40">
                <ProgressBar value={agent.performance_score ?? 0} tone="success" />
              </div>
              <span className="w-16 text-right text-xs font-semibold text-text">
                {agent.tasks_done} tasks
              </span>
            </div>
          ))}
        </CardBody>
      </Card>
    </div>
  );
}
