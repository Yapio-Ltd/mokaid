import { describe, expect, it } from "vitest";
import { useChatStore } from "@/stores/chat-store";

describe("chat streaming store", () => {
  it("concatenates chunks for the same streamId", () => {
    useChatStore.setState({ streamingDrafts: {}, finalizedStreamIds: {} });
    const store = useChatStore.getState();
    store.appendStreamChunk("agent-1", "s1", "Bonjour ");
    store.appendStreamChunk("agent-1", "s1", "Tom");
    expect(useChatStore.getState().streamingDrafts["agent-1"]).toEqual({
      streamId: "s1",
      text: "Bonjour Tom",
      finalized: false,
    });
  });

  it("ignores late chunks after finalizeStream", () => {
    useChatStore.setState({ streamingDrafts: {}, finalizedStreamIds: {} });
    useChatStore.getState().appendStreamChunk("agent-1", "s1", "Hello");
    useChatStore.getState().finalizeStream("agent-1", "s1");
    expect(useChatStore.getState().streamingDrafts["agent-1"]).toBeUndefined();
    useChatStore.getState().appendStreamChunk("agent-1", "s1", " leftover");
    expect(useChatStore.getState().streamingDrafts["agent-1"]).toBeUndefined();
  });

  it("keeps the full draft visible on done until the persisted message arrives", () => {
    useChatStore.setState({ streamingDrafts: {}, finalizedStreamIds: {} });
    useChatStore.getState().appendStreamChunk("agent-1", "s1", "Réponse complète");
    useChatStore.getState().markStreamDone("agent-1", "s1");

    expect(useChatStore.getState().streamingDrafts["agent-1"]).toEqual({
      streamId: "s1",
      text: "Réponse complète",
      finalized: true,
    });

    useChatStore.getState().appendStreamChunk("agent-1", "s1", " en retard");
    expect(useChatStore.getState().streamingDrafts["agent-1"]?.text).toBe("Réponse complète");
  });

  it("does not clear a different streamId on finalize", () => {
    useChatStore.setState({
      streamingDrafts: {
        "agent-1": { streamId: "s2", text: "new reply", finalized: false },
      },
      finalizedStreamIds: {},
    });
    useChatStore.getState().finalizeStream("agent-1", "s1");
    expect(useChatStore.getState().streamingDrafts["agent-1"]?.text).toBe("new reply");
  });
});
