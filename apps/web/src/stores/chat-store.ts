import { create } from "zustand";

/** Longest an agent can appear "typing" without a reply arriving. */
const TYPING_TIMEOUT_MS = 30_000;
const MAX_OPEN_WINDOWS = 3;
const SOUND_PREF_KEY = "mokaid.sounds";

interface StreamingDraft {
  streamId: string;
  text: string;
}

interface ChatState {
  /** Agent ids with an open chat window, oldest first. */
  openChatIds: string[];
  minimizedIds: string[];
  /** Agents currently composing a reply (typing indicator). */
  typingAgentIds: string[];
  /** In-progress agent replies, streamed token-by-token (typewriter). */
  streamingDrafts: Record<string, StreamingDraft>;
  soundEnabled: boolean;
  openChat: (agentId: string) => void;
  closeChat: (agentId: string) => void;
  toggleMinimize: (agentId: string) => void;
  setAgentTyping: (agentId: string) => void;
  clearAgentTyping: (agentId: string) => void;
  appendStreamChunk: (agentId: string, streamId: string, chunk: string) => void;
  clearStreamingDraft: (agentId: string) => void;
  toggleSound: () => void;
}

const typingTimers = new Map<string, ReturnType<typeof setTimeout>>();

export const useChatStore = create<ChatState>((set) => ({
  openChatIds: [],
  minimizedIds: [],
  typingAgentIds: [],
  streamingDrafts: {},
  soundEnabled: localStorage.getItem(SOUND_PREF_KEY) !== "off",

  openChat: (agentId) =>
    set((s) => {
      const already = s.openChatIds.includes(agentId);
      const openChatIds = already
        ? s.openChatIds
        : [...s.openChatIds, agentId].slice(-MAX_OPEN_WINDOWS);
      return {
        openChatIds,
        minimizedIds: s.minimizedIds.filter((id) => id !== agentId),
      };
    }),

  closeChat: (agentId) =>
    set((s) => ({
      openChatIds: s.openChatIds.filter((id) => id !== agentId),
      minimizedIds: s.minimizedIds.filter((id) => id !== agentId),
    })),

  toggleMinimize: (agentId) =>
    set((s) => ({
      minimizedIds: s.minimizedIds.includes(agentId)
        ? s.minimizedIds.filter((id) => id !== agentId)
        : [...s.minimizedIds, agentId],
    })),

  setAgentTyping: (agentId) => {
    clearTimeout(typingTimers.get(agentId));
    typingTimers.set(
      agentId,
      setTimeout(() => useChatStore.getState().clearAgentTyping(agentId), TYPING_TIMEOUT_MS),
    );
    set((s) => ({
      typingAgentIds: s.typingAgentIds.includes(agentId)
        ? s.typingAgentIds
        : [...s.typingAgentIds, agentId],
    }));
  },

  clearAgentTyping: (agentId) => {
    clearTimeout(typingTimers.get(agentId));
    typingTimers.delete(agentId);
    set((s) => ({ typingAgentIds: s.typingAgentIds.filter((id) => id !== agentId) }));
  },

  appendStreamChunk: (agentId, streamId, chunk) =>
    set((s) => {
      const current = s.streamingDrafts[agentId];
      // A new streamId supersedes any stale draft from a previous reply.
      const text = current?.streamId === streamId ? current.text + chunk : chunk;
      return { streamingDrafts: { ...s.streamingDrafts, [agentId]: { streamId, text } } };
    }),

  clearStreamingDraft: (agentId) =>
    set((s) => {
      if (!(agentId in s.streamingDrafts)) return s;
      const { [agentId]: _removed, ...rest } = s.streamingDrafts;
      return { streamingDrafts: rest };
    }),

  toggleSound: () =>
    set((s) => {
      const soundEnabled = !s.soundEnabled;
      localStorage.setItem(SOUND_PREF_KEY, soundEnabled ? "on" : "off");
      return { soundEnabled };
    }),
}));
