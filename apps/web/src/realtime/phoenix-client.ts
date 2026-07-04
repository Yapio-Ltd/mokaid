import { Socket, Channel, Presence } from "phoenix";
import { env } from "@/lib/env";
import { useAuthStore } from "@/stores/auth-store";

let socket: Socket | null = null;
const channels = new Map<string, Channel>();

export function getSocket(): Socket | null {
  const { token } = useAuthStore.getState();
  if (!token) return null;

  if (!socket) {
    socket = new Socket(env.VITE_WS_URL, {
      params: { token },
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

export function disconnect(): void {
  channels.forEach((channel) => channel.leave());
  channels.clear();
  socket?.disconnect();
  socket = null;
}

export { Presence };
export type { Channel };
