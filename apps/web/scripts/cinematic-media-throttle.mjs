import { createServer, request as httpRequest } from "node:http";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { performance } from "node:perf_hooks";

/** Single HTTP byte ranges, including suffix ranges; null means 416. */
export function mediaRange(header, size) {
  if (!Number.isSafeInteger(size) || size < 1) return null;
  if (!header) return { status: 200, start: 0, end: size - 1 };
  const match = /^bytes=(\d*)-(\d*)$/.exec(header);
  if (!match || (!match[1] && !match[2])) return null;
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix < 1) return null;
    return { status: 206, start: Math.max(0, size - suffix), end: size - 1 };
  }
  const start = Number(match[1]);
  const end = match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= size || end < start)
    return null;
  return { status: 206, start, end };
}

/** Same-origin local proxy. All MP4 connections share one bounded-rate scheduler. */
export async function createMediaThrottleProxy({
  upstreamOrigin,
  mediaPath,
  mediaFile,
  bytesPerSecond,
}) {
  const upstream = new URL(upstreamOrigin);
  if (
    upstream.protocol !== "http:" ||
    !["127.0.0.1", "localhost", "[::1]"].includes(upstream.hostname)
  )
    throw new Error("The throttle proxy only forwards to a local HTTP preview server");
  if (!Number.isFinite(bytesPerSecond) || bytesPerSecond < 1024)
    throw new Error("bytesPerSecond must be at least 1024");
  const { size } = await stat(mediaFile);
  const chunkBytes = 1024;
  const active = [];
  const upstreamRequests = new Set();
  const requests = [];
  const startedAt = performance.now();
  let transferredBytes = 0;
  let cursor = 0;
  const elapsed = () => Math.round(performance.now() - startedAt);

  const server = createServer((incoming, response) => {
    const path = new URL(incoming.url || "/", "http://127.0.0.1").pathname;
    if (path !== mediaPath) {
      if (!["GET", "HEAD"].includes(incoming.method || "GET")) {
        response.writeHead(405).end();
        return;
      }
      const forwarded = httpRequest(
        new URL(incoming.url || "/", upstream),
        {
          method: incoming.method,
          headers: { ...incoming.headers, host: upstream.host },
        },
        (remote) => {
          response.writeHead(remote.statusCode || 502, remote.headers);
          remote.pipe(response);
        },
      );
      upstreamRequests.add(forwarded);
      forwarded.on("close", () => upstreamRequests.delete(forwarded));
      forwarded.on("error", () => {
        if (!response.headersSent) response.writeHead(502);
        response.end();
      });
      response.on("close", () => forwarded.destroy());
      forwarded.end();
      return;
    }
    const range = mediaRange(incoming.headers.range, size);
    const entry = {
      range: incoming.headers.range || null,
      status: range?.status || 416,
      bytes: 0,
      startedMs: elapsed(),
      firstByteMs: null,
      lastByteMs: null,
      aborted: false,
    };
    requests.push(entry);
    if (!range) {
      response.writeHead(416, { "Content-Range": `bytes */${size}` }).end();
      return;
    }
    response.writeHead(range.status, {
      "Content-Type": "video/mp4",
      "Accept-Ranges": "bytes",
      "Cache-Control": "no-store",
      "Content-Length": range.end - range.start + 1,
      ...(range.status === 206
        ? { "Content-Range": `bytes ${range.start}-${range.end}/${size}` }
        : {}),
    });
    response.flushHeaders();
    if (incoming.method === "HEAD") {
      response.end();
      return;
    }
    const stream = createReadStream(mediaFile, {
      start: range.start,
      end: range.end,
      highWaterMark: chunkBytes,
    });
    const transfer = { stream, response, entry, blocked: false };
    active.push(transfer);
    // Keep the file paused. Only the shared scheduler can consume/read a chunk.
    stream.on("readable", () => {});
    stream.on("end", () => response.end());
    stream.on("error", () => response.destroy());
    response.on("close", () => {
      entry.aborted = !response.writableFinished;
      stream.destroy();
      const index = active.indexOf(transfer);
      if (index >= 0) active.splice(index, 1);
    });
  });
  const timer = setInterval(
    () => {
      if (!active.length) return;
      for (let tries = 0; tries < active.length; tries += 1) {
        const transfer = active[cursor++ % active.length];
        if (transfer.blocked || transfer.response.destroyed) continue;
        const chunk = transfer.stream.read(chunkBytes);
        if (!chunk) continue;
        transfer.entry.bytes += chunk.length;
        transfer.entry.firstByteMs ??= elapsed();
        transfer.entry.lastByteMs = elapsed();
        transferredBytes += chunk.length;
        if (!transfer.response.write(chunk)) {
          transfer.blocked = true;
          transfer.response.once("drain", () => {
            transfer.blocked = false;
          });
        }
        // Exactly one chunk across ALL active range requests per scheduler interval.
        break;
      }
    },
    Math.ceil((chunkBytes / bytesPerSecond) * 1000),
  );
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
  } catch (error) {
    clearInterval(timer);
    throw error;
  }
  const address = server.address();
  return {
    origin: `http://127.0.0.1:${address.port}`,
    snapshot: () => ({
      bytesPerSecond,
      chunkBytes,
      elapsedMs: elapsed(),
      transferredBytes,
      requests: requests.map((entry) => ({ ...entry })),
    }),
    async close() {
      clearInterval(timer);
      active.forEach(({ stream, response }) => {
        stream.destroy();
        response.destroy();
      });
      upstreamRequests.forEach((request) => request.destroy());
      await new Promise((resolve) => {
        server.close(resolve);
        server.closeAllConnections();
      });
    },
  };
}
