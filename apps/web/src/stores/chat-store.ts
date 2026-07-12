import { create } from "zustand";

/** Longest an agent can appear "typing" without a reply arriving. */
const TYPING_TIMEOUT_MS = 30_000;
const MAX_OPEN_WINDOWS = 3;
const SOUND_PREF_KEY = "mokaid.sounds";

interface StreamingDraft {
  streamId: string;
  text: string;
  /** Once the final message for this stream lands, ignore late chunks. */
  finalized: boolean;
}

interface ChatState {
  /** Agent ids with an open chat window, oldest first. */
  openChatIds: string[];
  minimizedIds: string[];
  /** Agents currently composing a reply (typing indicator). */
  typingAgentIds: string[];
  /** In-progress agent replies, streamed token-by-token (typewriter). */
  streamingDrafts: Record<string, StreamingDraft>;
  /** streamIds that already received their final message — reject late chunks. */
  finalizedStreamIds: Record<string, true>;
  /** Active conversation id per agent. null = latest / legacy. */
  activeConversationIds: Record<string, string | null>;
  /** When true the conversation list sidebar is shown for this agent. */
  historyOpenIds: string[];
  soundEnabled: boolean;
  openChat: (agentId: string) => void;
  closeChat: (agentId: string) => void;
  toggleMinimize: (agentId: string) => void;
  setAgentTyping: (agentId: string) => void;
  clearAgentTyping: (agentId: string) => void;
  appendStreamChunk: (agentId: string, streamId: string, chunk: string) => void;
  markStreamDone: (agentId: string, streamId: string) => void;
  finalizeStream: (agentId: string, streamId?: string | null) => void;
  clearStreamingDraft: (agentId: string) => void;
  setActiveConversation: (agentId: string, conversationId: string | null) => void;
  toggleHistory: (agentId: string) => void;
  toggleSound: () => void;
  setSoundEnabled: (enabled: boolean) => void;
}

const typingTimers = new Map<string, ReturnType<typeof setTimeout>>();

export const useChatStore = create<ChatState>((set) => ({
  openChatIds: [],
  minimizedIds: [],
  typingAgentIds: [],
  streamingDrafts: {},
  finalizedStreamIds: {},
  activeConversationIds: {},
  historyOpenIds: [],
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
      if (s.finalizedStreamIds[streamId]) return s;
      const current = s.streamingDrafts[agentId];
      if (current?.finalized && current.streamId === streamId) return s;
      const text =
        current?.streamId === streamId && !current.finalized ? current.text + chunk : chunk;
      return {
        streamingDrafts: {
          ...s.streamingDrafts,
          [agentId]: { streamId, text, finalized: false },
        },
      };
    }),

  markStreamDone: (agentId, streamId) =>
    set((s) => {
      const current = s.streamingDrafts[agentId];
      return {
        streamingDrafts:
          current?.streamId === streamId
            ? {
                ...s.streamingDrafts,
                [agentId]: { ...current, finalized: true },
              }
            : s.streamingDrafts,
        finalizedStreamIds: { ...s.finalizedStreamIds, [streamId]: true },
      };
    }),

  finalizeStream: (agentId, streamId) =>
    set((s) => {
      const current = s.streamingDrafts[agentId];
      if (streamId && current && current.streamId !== streamId) {
        return {
          finalizedStreamIds: { ...s.finalizedStreamIds, [streamId]: true },
        };
      }
      const { [agentId]: _removed, ...rest } = s.streamingDrafts;
      return {
        streamingDrafts: rest,
        finalizedStreamIds: streamId
          ? { ...s.finalizedStreamIds, [streamId]: true }
          : s.finalizedStreamIds,
      };
    }),

  clearStreamingDraft: (agentId) =>
    set((s) => {
      if (!(agentId in s.streamingDrafts)) return s;
      const { [agentId]: _removed, ...rest } = s.streamingDrafts;
      return { streamingDrafts: rest };
    }),

  setActiveConversation: (agentId, conversationId) =>
    set((s) => ({
      activeConversationIds: { ...s.activeConversationIds, [agentId]: conversationId },
      historyOpenIds: s.historyOpenIds.filter((id) => id !== agentId),
    })),

  toggleHistory: (agentId) =>
    set((s) => ({
      historyOpenIds: s.historyOpenIds.includes(agentId)
        ? s.historyOpenIds.filter((id) => id !== agentId)
        : [...s.historyOpenIds, agentId],
    })),

  toggleSound: () =>
    set((s) => {
      const soundEnabled = !s.soundEnabled;
      localStorage.setItem(SOUND_PREF_KEY, soundEnabled ? "on" : "off");
      return { soundEnabled };
    }),

  setSoundEnabled: (enabled) => {
    localStorage.setItem(SOUND_PREF_KEY, enabled ? "on" : "off");
    set({ soundEnabled: enabled });
  },
}));
