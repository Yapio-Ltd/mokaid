"use client";

import {
  ResponsiveContainer,
  LineChart,
  Line,
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  Area,
  AreaChart,
} from "recharts";

const COLORS = ["#3d8bfd", "#3ecf8e", "#f5a524", "#f31260", "#a78bfa", "#22d3ee"];

type SeriesPoint = Record<string, string | number | null | undefined>;

export function SimpleLineChart({
  data,
  xKey = "label",
  lines,
  height = 240,
}: {
  data: SeriesPoint[];
  xKey?: string;
  lines: Array<{ key: string; name: string; color?: string }>;
  height?: number;
}) {
  if (!data?.length) {
    return (
      <div className="flex h-48 items-center justify-center text-sm text-muted">
        Pas encore de données
      </div>
    );
  }

  return (
    <div style={{ width: "100%", height }}>
      <ResponsiveContainer>
        <LineChart data={data} margin={{ top: 8, right: 12, left: 0, bottom: 0 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="#2a3341" />
          <XAxis dataKey={xKey} stroke="#8b97a8" tick={{ fontSize: 11 }} />
          <YAxis stroke="#8b97a8" tick={{ fontSize: 11 }} width={48} />
          <Tooltip
            contentStyle={{
              background: "#1c222c",
              border: "1px solid #2a3341",
              borderRadius: 8,
              fontSize: 12,
            }}
          />
          <Legend />
          {lines.map((l, i) => (
            <Line
              key={l.key}
              type="monotone"
              dataKey={l.key}
              name={l.name}
              stroke={l.color || COLORS[i % COLORS.length]}
              strokeWidth={2}
              dot={false}
            />
          ))}
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}

export function SimpleBarChart({
  data,
  xKey = "label",
  bars,
  height = 240,
}: {
  data: SeriesPoint[];
  xKey?: string;
  bars: Array<{ key: string; name: string; color?: string }>;
  height?: number;
}) {
  if (!data?.length) {
    return (
      <div className="flex h-48 items-center justify-center text-sm text-muted">
        Pas encore de données
      </div>
    );
  }

  return (
    <div style={{ width: "100%", height }}>
      <ResponsiveContainer>
        <BarChart data={data} margin={{ top: 8, right: 12, left: 0, bottom: 0 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="#2a3341" />
          <XAxis dataKey={xKey} stroke="#8b97a8" tick={{ fontSize: 11 }} />
          <YAxis stroke="#8b97a8" tick={{ fontSize: 11 }} width={48} />
          <Tooltip
            contentStyle={{
              background: "#1c222c",
              border: "1px solid #2a3341",
              borderRadius: 8,
              fontSize: 12,
            }}
          />
          <Legend />
          {bars.map((b, i) => (
            <Bar
              key={b.key}
              dataKey={b.key}
              name={b.name}
              fill={b.color || COLORS[i % COLORS.length]}
              radius={[4, 4, 0, 0]}
            />
          ))}
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}

export function SimpleAreaChart({
  data,
  xKey = "label",
  areas,
  height = 240,
}: {
  data: SeriesPoint[];
  xKey?: string;
  areas: Array<{ key: string; name: string; color?: string }>;
  height?: number;
}) {
  if (!data?.length) {
    return (
      <div className="flex h-48 items-center justify-center text-sm text-muted">
        Pas encore de données
      </div>
    );
  }

  return (
    <div style={{ width: "100%", height }}>
      <ResponsiveContainer>
        <AreaChart data={data} margin={{ top: 8, right: 12, left: 0, bottom: 0 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="#2a3341" />
          <XAxis dataKey={xKey} stroke="#8b97a8" tick={{ fontSize: 11 }} />
          <YAxis stroke="#8b97a8" tick={{ fontSize: 11 }} width={48} />
          <Tooltip
            contentStyle={{
              background: "#1c222c",
              border: "1px solid #2a3341",
              borderRadius: 8,
              fontSize: 12,
            }}
          />
          <Legend />
          {areas.map((a, i) => (
            <Area
              key={a.key}
              type="monotone"
              dataKey={a.key}
              name={a.name}
              stroke={a.color || COLORS[i % COLORS.length]}
              fill={a.color || COLORS[i % COLORS.length]}
              fillOpacity={0.15}
            />
          ))}
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}

export function dayLabel(iso?: string | null): string {
  if (!iso) return "";
  try {
    return new Intl.DateTimeFormat("fr-FR", { month: "short", day: "numeric" }).format(
      new Date(iso),
    );
  } catch {
    return String(iso).slice(0, 10);
  }
}
