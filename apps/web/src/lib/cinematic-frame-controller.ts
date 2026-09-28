/** Scroll-linked frame pack: progressive window load, nearest-frame draw, cover canvas. */

export interface FramePack {
  pattern: string;
  firstIndex: number;
  count: number;
  fps: number;
  width: number;
  height: number;
}

export interface FrameControllerOptions {
  pack: FramePack;
  duration: number;
  canvas: HTMLCanvasElement;
  maxDecoded?: number;
  prefetchRadius?: number;
  maxConcurrent?: number;
  fetchImpl?: typeof fetch;
  createBitmap?: (blob: Blob) => Promise<ImageBitmap>;
  now?: () => number;
  onReady: () => void;
  onPresented: (time: number) => void;
  onError: () => void;
  onProgress?: (loaded: number, total: number) => void;
}

function frameUrl(pack: FramePack, index: number): string {
  return pack.pattern.replace("%05d", String(index).padStart(5, "0"));
}

function coverDraw(
  ctx: CanvasRenderingContext2D,
  bitmap: ImageBitmap,
  width: number,
  height: number,
) {
  const scale = Math.max(width / bitmap.width, height / bitmap.height);
  const drawW = bitmap.width * scale;
  const drawH = bitmap.height * scale;
  const x = (width - drawW) / 2;
  const y = (height - drawH) / 2;
  ctx.clearRect(0, 0, width, height);
  ctx.drawImage(bitmap, x, y, drawW, drawH);
}

/**
 * Ready on first presented frame; priority window + background fill.
 * Missing targets hold the nearest loaded frame. tick() uses the GSAP ticker.
 */
export function createCinematicFrameController(options: FrameControllerOptions) {
  const pack = options.pack;
  const fetchImpl = options.fetchImpl ?? fetch.bind(globalThis);
  const createBitmap =
    options.createBitmap ?? ((blob: Blob) => createImageBitmap(blob));
  const maxDecoded = options.maxDecoded ?? 48;
  const prefetchRadius = options.prefetchRadius ?? 16;
  const maxConcurrent = options.maxConcurrent ?? (pack.width <= 640 ? 6 : 10);
  const clock = options.now ?? (() => performance.now() / 1000);

  let disposed = false;
  let failed = false;
  let ready = false;
  let target = 0;
  let presentedIndex = -1;
  let decodeInFlight: Promise<void> | null = null;
  let loadStartedAt = 0;
  let inFlight = 0;
  const blobs = new Map<number, Blob>();
  const bitmaps = new Map<number, ImageBitmap>();
  const decodeOrder: number[] = [];
  const loading = new Set<number>();
  const queue: number[] = [];
  const queued = new Set<number>();

  const fail = () => {
    if (disposed || failed) return;
    failed = true;
    options.onError();
  };

  const timeToIndex = (time: number) => {
    const clamped = Math.max(0, Math.min(options.duration, time));
    const zeroBased = Math.round(clamped * pack.fps);
    return Math.min(pack.count, Math.max(pack.firstIndex, zeroBased + pack.firstIndex));
  };

  const indexToTime = (index: number) =>
    Math.max(0, Math.min(options.duration, (index - pack.firstIndex) / pack.fps));

  const touchDecoded = (index: number) => {
    const at = decodeOrder.indexOf(index);
    if (at >= 0) decodeOrder.splice(at, 1);
    decodeOrder.push(index);
    while (decodeOrder.length > maxDecoded) {
      const evict = decodeOrder.shift();
      if (evict === undefined) break;
      const bitmap = bitmaps.get(evict);
      if (bitmap) {
        bitmap.close();
        bitmaps.delete(evict);
      }
    }
  };

  const resizeCanvas = () => {
    const canvas = options.canvas;
    const dprCap = pack.width <= 640 ? 1.5 : 2;
    const dpr = Math.min(globalThis.devicePixelRatio || 1, dprCap);
    const cssWidth = Math.max(1, canvas.clientWidth || pack.width);
    const cssHeight = Math.max(1, canvas.clientHeight || pack.height);
    const width = Math.round(cssWidth * dpr);
    const height = Math.round(cssHeight * dpr);
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
    }
    return { width, height };
  };

  const nearestLoaded = (wanted: number) => {
    if (blobs.has(wanted)) return wanted;
    let best = -1;
    let bestDist = Number.POSITIVE_INFINITY;
    for (const index of blobs.keys()) {
      const dist = Math.abs(index - wanted);
      if (dist < bestDist || (dist === bestDist && index < best)) {
        best = index;
        bestDist = dist;
      }
    }
    return best;
  };

  const present = async (index: number) => {
    if (disposed || failed) return;
    let bitmap = bitmaps.get(index);
    if (!bitmap) {
      const blob = blobs.get(index);
      if (!blob) return;
      try {
        bitmap = await createBitmap(blob);
      } catch {
        fail();
        return;
      }
      if (disposed || failed) {
        bitmap.close();
        return;
      }
      bitmaps.set(index, bitmap);
      touchDecoded(index);
    } else {
      touchDecoded(index);
    }
    const ctx = options.canvas.getContext("2d");
    if (!ctx) {
      fail();
      return;
    }
    const { width, height } = resizeCanvas();
    coverDraw(ctx, bitmap, width, height);
    presentedIndex = index;
    if (!ready) {
      ready = true;
      options.onReady();
    }
    options.onPresented(indexToTime(index));
  };

  const pump = () => {
    while (inFlight < maxConcurrent && queue.length > 0 && !disposed && !failed) {
      const index = queue.shift();
      if (index === undefined) break;
      queued.delete(index);
      if (blobs.has(index) || loading.has(index)) continue;
      loading.add(index);
      inFlight += 1;
      void (async () => {
        try {
          const response = await fetchImpl(frameUrl(pack, index));
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          const blob = await response.blob();
          if (disposed || failed) return;
          blobs.set(index, blob);
          options.onProgress?.(blobs.size, pack.count);
          const wanted = timeToIndex(target);
          if (index === wanted || (!ready && index === pack.firstIndex)) {
            await present(index);
          } else if (ready && presentedIndex < 0) {
            await present(index);
          } else if (ready && !blobs.has(wanted)) {
            const near = nearestLoaded(wanted);
            if (near === index) await present(index);
          }
        } catch {
          // Background gaps are expected; only the opening frame is fatal.
          if (!ready && index === pack.firstIndex) fail();
        } finally {
          loading.delete(index);
          inFlight -= 1;
          if (!disposed && !failed) pump();
        }
      })();
    }
  };

  const enqueue = (index: number, priority: "front" | "back" = "back") => {
    if (
      disposed ||
      failed ||
      index < pack.firstIndex ||
      index > pack.count ||
      blobs.has(index) ||
      loading.has(index) ||
      queued.has(index)
    ) {
      return;
    }
    queued.add(index);
    if (priority === "front") queue.unshift(index);
    else queue.push(index);
    pump();
  };

  const ensureWindow = (center: number) => {
    const start = Math.max(pack.firstIndex, center - prefetchRadius);
    const end = Math.min(pack.count, center + prefetchRadius);
    const neighbors: number[] = [];
    for (let index = start; index <= end; index += 1) neighbors.push(index);
    neighbors.sort((a, b) => Math.abs(a - center) - Math.abs(b - center) || a - b);
    for (const index of neighbors) enqueue(index, "front");
  };

  const fillBackground = () => {
    // Remaining frames, nearest to current target first so scrub stays warm.
    const center = timeToIndex(target);
    const rest: number[] = [];
    for (let index = pack.firstIndex; index <= pack.count; index += 1) {
      if (!blobs.has(index) && !loading.has(index) && !queued.has(index)) rest.push(index);
    }
    rest.sort((a, b) => Math.abs(a - center) - Math.abs(b - center) || a - b);
    for (const index of rest) enqueue(index, "back");
  };

  loadStartedAt = clock();
  // Kick frame 0 (or first) immediately, then warm window + background fill.
  enqueue(pack.firstIndex, "front");
  ensureWindow(pack.firstIndex);
  fillBackground();

  return {
    request(time: number) {
      if (!Number.isFinite(time) || disposed || failed) return;
      target = Math.max(0, Math.min(options.duration, time));
      const index = timeToIndex(target);
      enqueue(index, "front");
      ensureWindow(index);
    },
    tick(nowSeconds: number) {
      if (disposed || failed) return;
      if (!ready) {
        if (loadStartedAt && nowSeconds - loadStartedAt > 8) fail();
        return;
      }
      const wanted = timeToIndex(target);
      if (wanted === presentedIndex && bitmaps.has(wanted)) return;

      const presentable = blobs.has(wanted) ? wanted : nearestLoaded(wanted);
      if (presentable < 0) {
        enqueue(wanted, "front");
        return;
      }
      if (presentable === presentedIndex && bitmaps.has(presentable) && presentable !== wanted) {
        enqueue(wanted, "front");
        ensureWindow(wanted);
        return;
      }
      if (decodeInFlight) return;
      decodeInFlight = present(presentable)
        .then(() => {
          ensureWindow(wanted);
        })
        .finally(() => {
          decodeInFlight = null;
        });
    },
    suspend() {
      loadStartedAt = clock();
    },
    redraw() {
      if (presentedIndex >= pack.firstIndex) void present(presentedIndex);
    },
    dispose() {
      disposed = true;
      for (const bitmap of bitmaps.values()) bitmap.close();
      bitmaps.clear();
      blobs.clear();
      decodeOrder.length = 0;
      queue.length = 0;
      queued.clear();
      loading.clear();
    },
  };
}

/** Pick desktop vs mobile pack from viewport / orientation. */
export function selectFramePack(
  frames: { desktop: FramePack; mobile: FramePack },
  query: { matches: boolean } | null,
): FramePack {
  if (query?.matches) return frames.mobile;
  return frames.desktop;
}

export const MOBILE_FRAME_QUERY = "(orientation: portrait) and (max-width: 900px)";
