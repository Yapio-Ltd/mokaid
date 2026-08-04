"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { AppShell } from "@/components/app-shell";
import { useAuthStore } from "@/lib/auth-store";

export default function ProtectedLayout({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const token = useAuthStore((s) => s.token);
  const user = useAuthStore((s) => s.user);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const finish = () => {
      const state = useAuthStore.getState();
      if (!state.token || !state.user?.is_platform_admin) {
        router.replace("/login");
      }
      setReady(true);
    };

    if (useAuthStore.persist.hasHydrated()) {
      finish();
    } else {
      const unsub = useAuthStore.persist.onFinishHydration(finish);
      return unsub;
    }
  }, [router]);

  useEffect(() => {
    if (!ready) return;
    if (!token || !user?.is_platform_admin) {
      router.replace("/login");
    }
  }, [ready, token, user, router]);

  if (!ready || !token || !user?.is_platform_admin) {
    return (
      <div className="flex min-h-screen items-center justify-center text-sm text-muted">
        Vérification de session…
      </div>
    );
  }

  return <AppShell>{children}</AppShell>;
}
