/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["./src/**/*.{js,ts,jsx,tsx,mdx}"],
  theme: {
    extend: {
      colors: {
        canvas: "#0f1217",
        surface: "#161b22",
        panel: "#1c222c",
        line: "#2a3341",
        ink: "#e8edf5",
        muted: "#8b97a8",
        accent: "#3d8bfd",
        accentSoft: "#1a3558",
        success: "#3ecf8e",
        warn: "#f5a524",
        danger: "#f31260",
      },
      fontFamily: {
        sans: ["var(--font-geist)", "IBM Plex Sans", "system-ui", "sans-serif"],
        display: ["var(--font-display)", "Source Serif 4", "Georgia", "serif"],
        mono: ["var(--font-mono)", "IBM Plex Mono", "ui-monospace", "monospace"],
      },
      boxShadow: {
        panel: "0 1px 0 rgba(255,255,255,0.04), 0 12px 40px rgba(0,0,0,0.35)",
      },
    },
  },
  plugins: [],
};
