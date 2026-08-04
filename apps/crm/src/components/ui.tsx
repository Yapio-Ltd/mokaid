"use client";

import { cn } from "@/lib/cn";

export function PageHeader({
  title,
  description,
  actions,
}: {
  title: string;
  description?: string;
  actions?: React.ReactNode;
}) {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 className="font-display text-2xl tracking-tight text-ink">{title}</h1>
        {description ? <p className="mt-1 text-sm text-muted">{description}</p> : null}
      </div>
      {actions ? <div className="flex flex-wrap items-center gap-2">{actions}</div> : null}
    </div>
  );
}

export function Card({
  children,
  className,
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "rounded-xl border border-line/80 bg-surface/80 shadow-panel backdrop-blur-sm",
        className,
      )}
    >
      {children}
    </div>
  );
}

export function Kpi({
  label,
  value,
  hint,
}: {
  label: string;
  value: string | number;
  hint?: string;
}) {
  return (
    <Card className="p-4">
      <div className="text-xs font-medium uppercase tracking-wider text-muted">{label}</div>
      <div className="mt-2 font-display text-2xl text-ink">{value}</div>
      {hint ? <div className="mt-1 text-xs text-muted">{hint}</div> : null}
    </Card>
  );
}

export function Button({
  children,
  variant = "primary",
  className,
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: "primary" | "ghost" | "danger" | "secondary";
}) {
  return (
    <button
      className={cn(
        "inline-flex items-center justify-center gap-2 rounded-lg px-3.5 py-2 text-sm font-medium transition disabled:opacity-50",
        variant === "primary" && "bg-accent text-white hover:brightness-110",
        variant === "secondary" && "border border-line bg-panel text-ink hover:bg-line/40",
        variant === "ghost" && "text-muted hover:bg-panel hover:text-ink",
        variant === "danger" && "bg-danger/90 text-white hover:brightness-110",
        className,
      )}
      {...props}
    >
      {children}
    </button>
  );
}

export function Input(props: React.InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      {...props}
      className={cn(
        "w-full rounded-lg border border-line bg-panel/80 px-3 py-2 text-sm text-ink outline-none placeholder:text-muted/70 focus:border-accent/60",
        props.className,
      )}
    />
  );
}

export function Select(props: React.SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <select
      {...props}
      className={cn(
        "rounded-lg border border-line bg-panel/80 px-3 py-2 text-sm text-ink outline-none focus:border-accent/60",
        props.className,
      )}
    />
  );
}

export function Textarea(props: React.TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return (
    <textarea
      {...props}
      className={cn(
        "w-full rounded-lg border border-line bg-panel/80 px-3 py-2 text-sm text-ink outline-none focus:border-accent/60",
        props.className,
      )}
    />
  );
}

export function Badge({
  children,
  tone = "neutral",
}: {
  children: React.ReactNode;
  tone?: "neutral" | "success" | "warn" | "danger" | "accent";
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium",
        tone === "neutral" && "bg-panel text-muted",
        tone === "success" && "bg-success/15 text-success",
        tone === "warn" && "bg-warn/15 text-warn",
        tone === "danger" && "bg-danger/15 text-danger",
        tone === "accent" && "bg-accentSoft text-accent",
      )}
    >
      {children}
    </span>
  );
}

export function Table({ children }: { children: React.ReactNode }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[640px] text-left text-sm">{children}</table>
    </div>
  );
}

export function Th({ children, className }: { children?: React.ReactNode; className?: string }) {
  return (
    <th
      className={cn(
        "border-b border-line px-4 py-3 text-xs font-medium uppercase tracking-wider text-muted",
        className,
      )}
    >
      {children}
    </th>
  );
}

export function Td({ children, className }: { children?: React.ReactNode; className?: string }) {
  return <td className={cn("border-b border-line/60 px-4 py-3 text-ink", className)}>{children}</td>;
}

export function Empty({ title }: { title: string }) {
  return <div className="px-4 py-10 text-center text-sm text-muted">{title}</div>;
}

export function Loading() {
  return <div className="px-4 py-10 text-center text-sm text-muted">Chargement…</div>;
}

export function Pagination({
  page,
  totalPages,
  onPage,
}: {
  page: number;
  totalPages: number;
  onPage: (p: number) => void;
}) {
  if (totalPages <= 1) return null;
  return (
    <div className="flex items-center justify-end gap-2 border-t border-line/70 px-4 py-3">
      <Button variant="ghost" disabled={page <= 1} onClick={() => onPage(page - 1)}>
        Précédent
      </Button>
      <span className="text-xs text-muted">
        {page} / {totalPages}
      </span>
      <Button variant="ghost" disabled={page >= totalPages} onClick={() => onPage(page + 1)}>
        Suivant
      </Button>
    </div>
  );
}

export function statusTone(status?: string | null): "neutral" | "success" | "warn" | "danger" | "accent" {
  switch (status) {
    case "active":
    case "paid":
      return "success";
    case "past_due":
    case "pending":
    case "invited":
      return "warn";
    case "suspended":
    case "disabled":
    case "canceled":
    case "void":
    case "expired":
      return "danger";
    default:
      return "neutral";
  }
}
