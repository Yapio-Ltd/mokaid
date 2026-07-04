/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  darkMode: "class",
  theme: {
    extend: {
      colors: {
        bg: "var(--mk-bg)",
        "bg-deep": "var(--mk-bg-deep)",
        surface: "var(--mk-surface)",
        "surface-raised": "var(--mk-surface-raised)",
        "surface-overlay": "var(--mk-surface-overlay)",
        "surface-hover": "var(--mk-surface-hover)",
        border: "var(--mk-border)",
        "border-strong": "var(--mk-border-strong)",
        primary: {
          DEFAULT: "rgb(var(--mk-primary-rgb) / <alpha-value>)",
          light: "var(--mk-primary-300)",
          dark: "var(--mk-primary-700)",
          muted: "var(--mk-primary-muted)",
        },
        success: {
          DEFAULT: "rgb(var(--mk-success-rgb) / <alpha-value>)",
          muted: "var(--mk-success-muted)",
        },
        warning: {
          DEFAULT: "rgb(var(--mk-warning-rgb) / <alpha-value>)",
          muted: "var(--mk-warning-muted)",
        },
        danger: {
          DEFAULT: "rgb(var(--mk-danger-rgb) / <alpha-value>)",
          muted: "var(--mk-danger-muted)",
        },
        info: {
          DEFAULT: "rgb(var(--mk-info-rgb) / <alpha-value>)",
          muted: "var(--mk-info-muted)",
        },
        text: {
          DEFAULT: "var(--mk-text)",
          secondary: "var(--mk-text-secondary)",
          muted: "var(--mk-text-muted)",
          disabled: "var(--mk-text-disabled)",
        },
      },
      borderRadius: {
        sm: "var(--mk-radius-sm)",
        md: "var(--mk-radius-md)",
        lg: "var(--mk-radius-lg)",
        xl: "var(--mk-radius-xl)",
      },
      boxShadow: {
        sm: "var(--mk-shadow-sm)",
        md: "var(--mk-shadow-md)",
        lg: "var(--mk-shadow-lg)",
        glow: "var(--mk-shadow-glow)",
      },
      fontFamily: {
        sans: ["Inter", "system-ui", "sans-serif"],
        mono: ["JetBrains Mono", "monospace"],
      },
    },
  },
  plugins: [],
};
