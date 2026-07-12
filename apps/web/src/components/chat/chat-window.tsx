import { useEffect, useMemo, useRef, useState } from "react";
import { AnimatePresence } from "framer-motion";
import { History, Loader2, Minus, Paperclip, Plus, Send, Upload, X } from "lucide-react";
import type { Agent, AgentChatConversation } from "@/api/types";
import {
  useAgentChatMessages,
  useAgentConversations,
  useMarkAgentChatRead,
  useNewConversation,
  useSendAgentChatMessage,
  useUploadDriveFile,
} from "@/api/hooks";
import { AgentAvatar } from "@/components/agents/agent-avatar";
import { ChatAttachmentView } from "./chat-attachment";
import { FadeSlide } from "@/components/ui/motion";
import { Tooltip } from "@/components/ui/tooltip";
import { useChatStore } from "@/stores/chat-store";
import { playSound } from "@/lib/sounds";
import { toast } from "@/stores/toast-store";
import { cn } from "@/lib/cn";

function formatTime(iso: string): string {
  const date = new Date(iso);
  const now = new Date();
  const sameDay = date.toDateString() === now.toDateString();
  const time = date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  return sameDay ? time : `${date.toLocaleDateString([], { day: "numeric", month: "short" })} ${time}`;
}

function TypingDots() {
  return (
    <span className="inline-flex items-center gap-1 px-1" aria-label="typing">
      {[0, 1, 2].map((i) => (
        <span
          key={i}
          className="h-1.5 w-1.5 animate-bounce rounded-full bg-text-muted"
          style={{ animationDelay: `${i * 150}ms` }}
        />
      ))}
    </span>
  );
}

/** A file staged for sending (uploaded to Drive, awaiting the chat message). */
interface PendingFile {
  driveItemId: string;
  name: string;
}

function ConversationList({
  conversations,
  activeConvId,
  onSelect,
}: {
  conversations: AgentChatConversation[];
  activeConvId: string | null;
  onSelect: (convId: string | null) => void;
}) {
  return (
    <div className="flex flex-1 flex-col overflow-y-auto">
      <p className="px-3 py-2 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
        Conversations
      </p>
      {conversations.length === 0 && (
        <p className="px-3 py-2 text-xs text-text-muted">No conversations yet.</p>
      )}
      {conversations.map((conv) => {
        const isActive = conv.id === activeConvId;
        const title = conv.title || "New conversation";
        const date = new Date(conv.inserted_at);
        const dateStr = date.toLocaleDateString([], { day: "numeric", month: "short" });
        return (
          <button
            key={conv.id}
            type="button"
            onClick={() => onSelect(conv.id)}
            className={cn(
              "flex w-full items-center gap-2 px-3 py-2 text-left transition-colors hover:bg-surface-hover",
              isActive && "bg-primary-muted/40",
            )}
          >
            <span className="min-w-0 flex-1">
              <span className="block truncate text-[12px] font-medium text-text">{title}</span>
              <span className="block text-[10px] text-text-muted">
                {dateStr}
                {conv.status === "archived" && " · archived"}
              </span>
            </span>
          </button>
        );
      })}
    </div>
  );
}

export function ChatWindow({ agent }: { agent: Agent }) {
  const closeChat = useChatStore((s) => s.closeChat);
  const toggleMinimize = useChatStore((s) => s.toggleMinimize);
  const minimized = useChatStore((s) => s.minimizedIds.includes(agent.id));
  const typing = useChatStore((s) => s.typingAgentIds.includes(agent.id));
  const streamingDraft = useChatStore((s) => s.streamingDrafts[agent.id]);
  const streamedReply = streamingDraft?.text ?? "";
  const activeConvId = useChatStore((s) => s.activeConversationIds[agent.id] ?? null);
  const historyOpen = useChatStore((s) => s.historyOpenIds.includes(agent.id));
  const setActiveConversation = useChatStore((s) => s.setActiveConversation);
  const toggleHistory = useChatStore((s) => s.toggleHistory);

  const { data } = useAgentChatMessages(agent.id, activeConvId);
  const messages = useMemo(() => data?.data ?? [], [data]);

  const { data: convData } = useAgentConversations(agent.id);
  const conversations = useMemo(() => convData?.data ?? [], [convData]);

  const send = useSendAgentChatMessage(agent.id);
  const newConv = useNewConversation(agent.id);
  const uploadFile = useUploadDriveFile();
  const markRead = useMarkAgentChatRead();
  const markReadMutate = markRead.mutate;

  const handleNewConversation = () => {
    newConv.mutate(undefined, {
      onSuccess: (result) => {
        setActiveConversation(agent.id, result.data.id);
      },
    });
  };

  const [draft, setDraft] = useState("");
  const [pending, setPending] = useState<PendingFile[]>([]);
  const [uploading, setUploading] = useState(false);
  const [dragOver, setDragOver] = useState(false);
  const dragDepth = useRef(0);
  const scrollRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  // Keep the read cursor in sync while the window is open (badge clears).
  const lastMessageId = messages.at(-1)?.id;
  useEffect(() => {
    if (!minimized && lastMessageId) markReadMutate(agent.id);
  }, [agent.id, lastMessageId, minimized, markReadMutate]);

  // Pin the scroll to the latest message / typing indicator / live draft.
  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight });
  }, [lastMessageId, typing, minimized, pending.length, streamedReply]);

  const uploadFiles = async (files: File[]) => {
    if (files.length === 0) return;
    setUploading(true);
    try {
      const results = await Promise.all(
        files.map((file) =>
          uploadFile.mutateAsync({ file, parentId: null }).then((r) => ({
            driveItemId: r.data.id,
            name: r.data.name,
          })),
        ),
      );
      setPending((prev) => [...prev, ...results]);
      inputRef.current?.focus();
    } catch {
      toast({ tone: "error", title: "Upload failed", description: "Could not attach the file(s)." });
    } finally {
      setUploading(false);
    }
  };

  const submit = () => {
    const body = draft.trim();
    if ((!body && pending.length === 0) || send.isPending) return;
    const driveIds = pending.map((p) => p.driveItemId);
    setDraft("");
    setPending([]);
    playSound("sent");
    // Optimistic typing: the agent appears to compose the instant the message
    // leaves — the server broadcast then keeps (or clears) the indicator.
    if (agent.kind === "ai") useChatStore.getState().setAgentTyping(agent.id);
    send.mutate(driveIds.length > 0 ? { body, drive_item_ids: driveIds } : body);
    inputRef.current?.focus();
  };

  // Drag & drop: depth counter avoids flicker as the cursor crosses children.
  const onDragEnter = (e: React.DragEvent) => {
    if (![...e.dataTransfer.types].includes("Files")) return;
    dragDepth.current += 1;
    setDragOver(true);
  };
  const onDragLeave = () => {
    dragDepth.current = Math.max(0, dragDepth.current - 1);
    if (dragDepth.current === 0) setDragOver(false);
  };
  const onDrop = (e: React.DragEvent) => {
    e.preventDefault();
    dragDepth.current = 0;
    setDragOver(false);
    const files = [...e.dataTransfer.files];
    if (files.length > 0) void uploadFiles(files);
  };

  const online = agent.presence_status === "online";
  const busy = agent.status === "busy" || agent.status === "active";

  const viewingArchived = useMemo(() => {
    if (!activeConvId) return false;
    return conversations.some((c) => c.id === activeConvId && c.status === "archived");
  }, [activeConvId, conversations]);

  const canSend = !viewingArchived && (draft.trim().length > 0 || pending.length > 0) && !send.isPending;

  return (
    <div
      onDragEnter={onDragEnter}
      onDragOver={(e) => {
        if ([...e.dataTransfer.types].includes("Files")) e.preventDefault();
      }}
      onDragLeave={onDragLeave}
      onDrop={onDrop}
      className={cn(
        "pointer-events-auto relative flex w-80 flex-col overflow-hidden rounded-xl border bg-surface shadow-lg",
        dragOver ? "border-primary shadow-glow" : "border-border-strong",
        minimized ? "h-auto" : "h-[26rem]",
      )}
    >
      {/* Drop overlay */}
      {dragOver && !minimized && (
        <div className="pointer-events-none absolute inset-0 z-10 flex flex-col items-center justify-center gap-2 bg-primary-muted/70 backdrop-blur-sm">
          <Upload size={26} className="text-primary-light" />
          <p className="text-sm font-semibold text-text">Drop to hand it to {agent.display_name}</p>
          <p className="text-[11px] text-text-secondary">They'll get straight to work on it.</p>
        </div>
      )}

      {/* Header */}
      <button
        type="button"
        onClick={() => toggleMinimize(agent.id)}
        className="flex w-full items-center gap-2.5 border-b border-border bg-surface-raised px-3 py-2 text-left transition-colors hover:bg-surface-hover"
      >
        <span className="relative">
          <AgentAvatar agent={agent} size="sm" showBadge={false} />
          <span
            className={cn(
              "absolute -bottom-0.5 -right-0.5 h-2.5 w-2.5 rounded-full ring-2 ring-surface-raised",
              busy ? "animate-pulse bg-warning" : online ? "bg-success" : "bg-text-disabled",
            )}
          />
        </span>
        <span className="min-w-0 flex-1">
          <Tooltip
            content={
              agent.skills?.length ? (
                <span>
                  <span className="font-semibold">Skills</span>
                  <br />
                  {agent.skills.map((s) => s.name).join(" · ")}
                </span>
              ) : (
                agent.role_title ?? "AI teammate"
              )
            }
          >
            <span className="block truncate text-sm font-semibold text-text">
              {agent.display_name}
            </span>
          </Tooltip>
          <span className="block truncate text-[11px] text-text-muted">
            {busy ? "Working on a task…" : agent.role_title ?? "AI teammate"}
          </span>
        </span>
        <span className="flex items-center gap-0.5">
          <Tooltip content="New conversation">
            <span
              role="button"
              aria-label="New conversation"
              onClick={(event) => {
                event.stopPropagation();
                handleNewConversation();
              }}
              className="rounded-md p-1.5 text-text-muted hover:bg-surface-hover hover:text-text"
            >
              <Plus size={14} />
            </span>
          </Tooltip>
          <Tooltip content="Conversation history">
            <span
              role="button"
              aria-label="Conversation history"
              onClick={(event) => {
                event.stopPropagation();
                toggleHistory(agent.id);
              }}
              className={cn(
                "rounded-md p-1.5 text-text-muted hover:bg-surface-hover hover:text-text",
                historyOpen && "bg-surface-hover text-text",
              )}
            >
              <History size={14} />
            </span>
          </Tooltip>
          <span
            role="button"
            aria-label={minimized ? "Expand chat" : "Minimize chat"}
            className="rounded-md p-1.5 text-text-muted hover:bg-surface-hover hover:text-text"
          >
            <Minus size={14} />
          </span>
          <span
            role="button"
            aria-label="Close chat"
            onClick={(event) => {
              event.stopPropagation();
              closeChat(agent.id);
            }}
            className="rounded-md p-1.5 text-text-muted hover:bg-surface-hover hover:text-text"
          >
            <X size={14} />
          </span>
        </span>
      </button>

      {!minimized && historyOpen && (
        <ConversationList
          conversations={conversations}
          activeConvId={activeConvId}
          onSelect={(convId) => setActiveConversation(agent.id, convId)}
        />
      )}

      {!minimized && !historyOpen && (
        <>
          {/* Messages */}
          <div ref={scrollRef} className="flex-1 space-y-2.5 overflow-y-auto px-3 py-3">
            {messages.length === 0 && !typing && (
              <div className="flex h-full flex-col items-center justify-center gap-2 px-4 text-center">
                <AgentAvatar agent={agent} size="lg" showRing={false} />
                <p className="text-sm font-medium text-text">{agent.display_name}</p>
                <p className="text-xs text-text-muted">
                  Ask a question, or drop a file to put {agent.display_name} to work — they'll deliver
                  the result right here.
                </p>
              </div>
            )}

            <AnimatePresence initial={false}>
              {messages.map((message) => {
                const isAgent = message.author_kind === "agent";
                return (
                  <FadeSlide
                    key={message.id}
                    className={cn("flex items-end gap-2", !isAgent && "justify-end")}
                  >
                    {isAgent && (
                      <AgentAvatar agent={agent} size="xs" showRing={false} showBadge={false} />
                    )}
                    <div
                      className={cn(
                        "max-w-[78%] rounded-2xl px-3 py-2 text-[13px] leading-snug",
                        isAgent
                          ? "rounded-bl-sm bg-surface-raised text-text"
                          : "rounded-br-sm bg-primary text-white",
                      )}
                      title={
                        isAgent
                          ? formatTime(message.inserted_at)
                          : `${message.author_name ?? "You"} · ${formatTime(message.inserted_at)}`
                      }
                    >
                      {message.body && <p className="whitespace-pre-wrap">{message.body}</p>}
                      {message.attachments.map((att) => (
                        <ChatAttachmentView
                          key={att.drive_item_id}
                          attachment={att}
                          tone={isAgent ? "agent" : "member"}
                        />
                      ))}
                    </div>
                  </FadeSlide>
                );
              })}
            </AnimatePresence>

            {/* Live streamed draft (typewriter): the reply grows token by
                token, then the persisted message replaces it. */}
            {streamedReply && (
              <div className="flex items-end gap-2">
                <AgentAvatar agent={agent} size="xs" showRing={false} showBadge={false} />
                <div className="max-w-[78%] rounded-2xl rounded-bl-sm bg-surface-raised px-3 py-2 text-[13px] leading-snug text-text">
                  <p className="whitespace-pre-wrap">
                    {streamedReply}
                    {!streamingDraft?.finalized && (
                      <span className="ml-0.5 inline-block h-3.5 w-[2px] animate-pulse bg-text-muted align-middle" />
                    )}
                  </p>
                </div>
              </div>
            )}

            {typing && !streamedReply && (
              <div className="flex items-end gap-2">
                <AgentAvatar agent={agent} size="xs" showRing={false} showBadge={false} />
                <div className="rounded-2xl rounded-bl-sm bg-surface-raised px-3 py-2.5">
                  <TypingDots />
                </div>
              </div>
            )}
          </div>

          {/* Pending attachments (staged before send) */}
          {(pending.length > 0 || uploading) && (
            <div className="flex flex-wrap gap-1.5 border-t border-border px-3 pt-2.5">
              {pending.map((file) => (
                <span
                  key={file.driveItemId}
                  className="flex items-center gap-1.5 rounded-md border border-border bg-surface-raised px-2 py-1"
                >
                  <Paperclip size={11} className="text-primary-light" />
                  <span className="max-w-[120px] truncate text-[11px] text-text">{file.name}</span>
                  <button
                    type="button"
                    aria-label="Remove attachment"
                    onClick={() =>
                      setPending((prev) => prev.filter((p) => p.driveItemId !== file.driveItemId))
                    }
                    className="text-text-muted hover:text-danger"
                  >
                    <X size={11} />
                  </button>
                </span>
              ))}
              {uploading && (
                <span className="flex items-center gap-1.5 text-[11px] text-text-muted">
                  <Loader2 size={11} className="animate-spin" />
                  Uploading…
                </span>
              )}
            </div>
          )}

          {/* Composer or archived notice */}
          {viewingArchived ? (
            <div className="flex items-center justify-between border-t border-border px-3 py-2.5">
              <span className="text-[11px] text-text-muted">Archived conversation</span>
              <button
                type="button"
                onClick={() => setActiveConversation(agent.id, null)}
                className="rounded-md bg-primary px-3 py-1 text-[11px] font-medium text-white hover:opacity-90"
              >
                Back to current
              </button>
            </div>
          ) : (
            <div className="flex items-end gap-1.5 border-t border-border px-3 py-2.5">
              <input
                ref={fileInputRef}
                type="file"
                multiple
                className="hidden"
                onChange={(e) => {
                  void uploadFiles([...(e.target.files ?? [])]);
                  e.target.value = "";
                }}
              />
              <button
                type="button"
                onClick={() => fileInputRef.current?.click()}
                aria-label="Attach a file"
                title="Attach a file"
                className="rounded-lg p-2 text-text-muted transition-colors hover:bg-surface-hover hover:text-text"
              >
                <Paperclip size={15} />
              </button>
              <textarea
                ref={inputRef}
                value={draft}
                onChange={(event) => setDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" && !event.shiftKey) {
                    event.preventDefault();
                    submit();
                  }
                }}
                rows={1}
                placeholder={`Message ${agent.display_name}…`}
                className="max-h-24 min-h-[2.25rem] flex-1 resize-none rounded-lg border border-border bg-bg px-3 py-2 text-[13px] text-text placeholder:text-text-disabled focus:border-primary focus:outline-none"
              />
              <button
                type="button"
                onClick={submit}
                disabled={!canSend}
                aria-label="Send message"
                className="rounded-lg bg-primary p-2 text-white transition-opacity hover:opacity-90 disabled:opacity-40"
              >
                <Send size={15} />
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}
