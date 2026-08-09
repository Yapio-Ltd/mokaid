import { create } from "zustand";
import { persist } from "zustand/middleware";

/** Dynamic import — never pull Babylon into the auth/landing entry graph. */
function disposeOfficeHostLazy() {
  void import("@/three/office-scene-host").then((m) => m.disposeOfficeHost());
}

export interface AuthUser {
  id: string;
  email: string;
  full_name: string;
  avatar_url: string | null;
  /** Local password account (not Google/Cognito-only). */
  has_password?: boolean;
  has_avatar?: boolean;
  locale?: string;
  timezone?: string;
  mfa_enabled?: boolean;
  last_login_at?: string | null;
  auth_provider?: "google" | "password" | "sso" | string;
}

export interface WorkspaceSummary {
  id: string;
  name: string;
  slug: string;
  logo_url: string | null;
  role_name?: string;
}

interface AuthState {
  token: string | null;
  user: AuthUser | null;
  workspaceId: string | null;
  workspaces: WorkspaceSummary[];
  setSession: (token: string, user: AuthUser) => void;
  /** Atomically set auth + workspaces so a stale workspaceId from another account never leaks. */
  establishSession: (
    token: string,
    user: AuthUser,
    workspaces: WorkspaceSummary[],
  ) => void;
  patchUser: (patch: Partial<AuthUser>) => void;
  setWorkspaces: (workspaces: WorkspaceSummary[]) => void;
  selectWorkspace: (id: string) => void;
  addWorkspace: (workspace: WorkspaceSummary) => void;
  patchWorkspace: (id: string, patch: Partial<WorkspaceSummary>) => void;
  logout: () => void;
}

function pickWorkspaceId(
  workspaces: WorkspaceSummary[],
  preferred: string | null | undefined,
): string | null {
  if (preferred && workspaces.some((w) => w.id === preferred)) return preferred;
  return workspaces[0]?.id ?? null;
}

export const useAuthStore = create<AuthState>()(
  persist(
    (set, get) => ({
      token: null,
      user: null,
      workspaceId: null,
      workspaces: [],
      setSession: (token, user) => set({ token, user }),
      establishSession: (token, user, workspaces) => {
        const prevWorkspace = get().workspaceId;
        const nextWorkspace = pickWorkspaceId(workspaces, prevWorkspace);
        if (prevWorkspace && nextWorkspace && prevWorkspace !== nextWorkspace) {
          disposeOfficeHostLazy();
        }
        set({
          token,
          user,
          workspaces,
          workspaceId: nextWorkspace,
        });
      },
      patchUser: (patch) =>
        set((state) => (state.user ? { user: { ...state.user, ...patch } } : state)),
      setWorkspaces: (workspaces) =>
        set((state) => ({
          workspaces,
          workspaceId: pickWorkspaceId(workspaces, state.workspaceId),
        })),
      selectWorkspace: (id) => {
        // Drop the WebGL context when switching workspaces so seats/POIs remount cleanly.
        const prev = get().workspaceId;
        if (prev && prev !== id) disposeOfficeHostLazy();
        set({ workspaceId: id });
      },
      addWorkspace: (workspace) =>
        set((state) => ({ workspaces: [...state.workspaces, workspace] })),
      patchWorkspace: (id, patch) =>
        set((state) => ({
          workspaces: state.workspaces.map((w) => (w.id === id ? { ...w, ...patch } : w)),
        })),
      logout: () => {
        disposeOfficeHostLazy();
        set({ token: null, user: null, workspaceId: null, workspaces: [] });
      },
    }),
    { name: "mokaid-auth" },
  ),
);
