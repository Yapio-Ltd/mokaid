import { Socket, Channel, Presence } from "phoenix";
import { browserCsrfToken } from "@/lib/browser-session";
import { resolveWsUrl } from "@/lib/env";
import { useAuthStore } from "@/stores/auth-store";

let socket: Socket | null = null;
const channels = new Map<string, Channel>();

export function getSocket(): Socket | null {
  const { token } = useAuthStore.getState();
  if (!token) return null;

  if (!socket) {
    socket = new Socket(resolveWsUrl(), {
      params: () => {
        const current = useAuthStore.getState().token;
        const csrf = browserCsrfToken(current);
        return csrf ? { _csrf_token: csrf } : { token: current };
      },
      reconnectAfterMs: (tries: number) => Math.min(1000 * 2 ** tries, 10_000),
    });
    socket.connect();
  }

  return socket;
}

export function joinChannel(topic: string, params: Record<string, unknown> = {}): Channel | null {
  const existing = channels.get(topic);
  if (existing) return existing;

  const currentSocket = getSocket();
  if (!currentSocket) return null;

  const channel = currentSocket.channel(topic, params);
  channel.join().receive("error", (reason) => {
    console.warn(`[realtime] failed to join ${topic}`, reason);
    // Drop the failed channel so a later joinChannel call can retry cleanly.
    if (channels.get(topic) === channel) {
      channel.leave();
      channels.delete(topic);
    }
  });
  channels.set(topic, channel);
  return channel;
}

export function leaveChannel(topic: string): void {
  const channel = channels.get(topic);
  if (channel) {
    channel.leave();
    channels.delete(topic);
  }
}

/**
 * Runs `cb` every time the socket (re)connects. Returns an unsubscribe
 * function, or null when there is no socket yet (no auth token).
 */
export function onSocketOpen(cb: () => void): (() => void) | null {
  const currentSocket = getSocket();
  if (!currentSocket) return null;
  const ref = currentSocket.onOpen(cb);
  return () => currentSocket.off([ref]);
}

export function disconnect(): void {
  channels.forEach((channel) => channel.leave());
  channels.clear();
  socket?.disconnect();
  socket = null;
}

export { Presence };
export type { Channel };
