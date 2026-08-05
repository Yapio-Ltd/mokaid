"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import {
  Activity,
  Building2,
  CreditCard,
  DollarSign,
  FileText,
  LayoutDashboard,
  LogOut,
  Mail,
  Receipt,
  ScrollText,
  Shield,
  Users,
  Wallet,
  Package,
} from "lucide-react";
import { cn } from "@/lib/cn";
import { useAuthStore } from "@/lib/auth-store";

const nav = [
  { href: "/", label: "Dashboard", icon: LayoutDashboard },
  { href: "/costs", label: "Coûts", icon: DollarSign },
  { href: "/users", label: "Utilisateurs", icon: Users },
  { href: "/workspaces", label: "Workspaces", icon: Building2 },
  { href: "/subscriptions", label: "Abonnements", icon: CreditCard },
  { href: "/plans", label: "Forfaits", icon: Package },
  { href: "/invoices", label: "Factures", icon: Receipt },
  { href: "/credits", label: "Crédits", icon: Wallet },
  { href: "/usage", label: "Usage AI", icon: Activity },
  { href: "/members", label: "Membres", icon: Users },
  { href: "/invites", label: "Invitations", icon: Mail },
  { href: "/audit-logs", label: "Audit logs", icon: ScrollText },
  { href: "/logs", label: "Logs globaux", icon: Shield },
];

export function AppShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const router = useRouter();
  const user = useAuthStore((s) => s.user);
  const clear = useAuthStore((s) => s.clear);

  return (
    <div className="flex min-h-screen">
      <aside className="sticky top-0 flex h-screen w-60 shrink-0 flex-col border-r border-line/80 bg-surface/90 backdrop-blur-md">
        <div className="border-b border-line/80 px-5 py-5">
          <div className="font-display text-xl tracking-tight text-ink">Mokaid</div>
          <div className="mt-0.5 text-xs font-medium uppercase tracking-[0.18em] text-muted">
            Operator CRM
          </div>
        </div>
        <nav className="flex-1 space-y-0.5 overflow-y-auto px-2 py-3">
          {nav.map((item) => {
            const active =
              item.href === "/"
                ? pathname === "/"
                : pathname === item.href || pathname.startsWith(`${item.href}/`);
            const Icon = item.icon;
            return (
              <Link
                key={item.href}
                href={item.href}
                className={cn(
                  "flex items-center gap-2.5 rounded-lg px-3 py-2 text-sm transition-colors",
                  active
                    ? "bg-accentSoft text-ink"
                    : "text-muted hover:bg-panel hover:text-ink",
                )}
              >
                <Icon className="h-4 w-4 shrink-0 opacity-80" />
                {item.label}
              </Link>
            );
          })}
        </nav>
        <div className="border-t border-line/80 p-3">
          <div className="mb-2 truncate px-2 text-xs text-muted">{user?.email}</div>
          <button
            type="button"
            onClick={() => {
              clear();
              router.replace("/login");
            }}
            className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-sm text-muted transition hover:bg-panel hover:text-ink"
          >
            <LogOut className="h-4 w-4" />
            Déconnexion
          </button>
        </div>
      </aside>
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-10 flex h-14 items-center justify-between border-b border-line/70 bg-canvas/70 px-6 backdrop-blur-md">
          <div className="text-sm text-muted">
            <FileText className="mr-2 inline h-3.5 w-3.5 opacity-70" />
            Console opérateur cross-tenant
          </div>
          <div className="text-sm font-medium text-ink">{user?.full_name || "Admin"}</div>
        </header>
        <main className="flex-1 px-6 py-6">{children}</main>
      </div>
    </div>
  );
}
