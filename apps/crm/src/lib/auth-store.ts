"use client";

import { create } from "zustand";
import { persist } from "zustand/middleware";
import type { AdminUser } from "./types";

type AuthState = {
  token: string | null;
  user: AdminUser | null;
  setSession: (token: string, user: AdminUser) => void;
  clear: () => void;
};

export const useAuthStore = create<AuthState>()(
  persist(
    (set) => ({
      token: null,
      user: null,
      setSession: (token, user) => set({ token, user }),
      clear: () => set({ token: null, user: null }),
    }),
    { name: "mokaid-crm-auth" },
  ),
);
