/**
 * mokaid design tokens — programmatic access for charts, 3D scene and canvas layers
 * (which cannot read CSS variables at initialization time).
 */

export const colors = {
  bg: "#0b0b10",
  bgDeep: "#08080c",
  surface: "#12121a",
  surfaceRaised: "#17171f",
  surfaceOverlay: "#1c1c26",
  border: "#232330",
  borderStrong: "#2e2e3e",

  primary: "#7c5cff",
  primaryLight: "#ab95ff",
  primaryDark: "#5936d1",

  success: "#34d399",
  warning: "#fbbf24",
  danger: "#f87171",
  info: "#60a5fa",

  text: "#f4f4f8",
  textSecondary: "#a3a3b8",
  textMuted: "#6b6b80",
} as const;

/** Colors used for agent status indicators (UI badges + 3D avatar accents). */
export const statusColors = {
  active: colors.success,
  busy: colors.warning,
  idle: "#8f72ff",
  waiting: colors.warning,
  blocked: colors.danger,
  away: "#f59e0b",
  offline: "#4a4a5c",
  archived: "#4a4a5c",
  online: colors.success,
} as const;

export const chartPalette = [
  "#7c5cff",
  "#34d399",
  "#60a5fa",
  "#fbbf24",
  "#f87171",
  "#22d3ee",
  "#f472b6",
  "#a3e635",
] as const;

export type StatusColorKey = keyof typeof statusColors;
