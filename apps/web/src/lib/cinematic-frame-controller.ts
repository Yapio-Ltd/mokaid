/** Scroll-linked frame pack: download gate, windowed decode, cover canvas draw. */

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
  fetchImpl?: typeof fetch;
  createBitmap?: (blob: Blob) => Promise<ImageBitmap>;
  now?: () => number;
  onReady: () => void;
  onPresented: (time: number) => void;
  onError: () => void;
  onProgress?: (loaded: number, total: number) => void;
}

function frameUrl(pack: FramePack, index: number): string {
  // pattern uses printf-style %05d; frames are 1-based.
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
 * One replaceable target time, LRU-decoded bitmaps, full-pack download before ready.
 * tick() belongs to the existing GSAP ticker — never a second RAF loop.
 */
export function createCinematicFrameController(options: FrameControllerOptions) {
  const pack = options.pack;
  const fetchImpl = options.fetchImpl ?? fetch.bind(globalThis);
  const createBitmap =
    options.createBitmap ?? ((blob: Blob) => createImageBitmap(blob));
  const maxDecoded = options.maxDecoded ?? 64;
  const prefetchRadius = options.prefetchRadius ?? 24;
  const clock = options.now ?? (() => performance.now() / 1000);

  let disposed = false;
  let failed = false;
  let ready = false;
  let target = 0;
  let presentedIndex = -1;
  let decodeInFlight: Promise<void> | null = null;
  let loadStartedAt = 0;
  let stallStartedAt = 0;

  const blobs = new Map<number, Blob>();
  const bitmaps = new Map<number, ImageBitmap>();
  const decodeOrder: number[] = [];
  const loading = new Set<number>();

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
    const dprCap = pack.width <= 960 ? 1.5 : 2;
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
    options.onPresented(indexToTime(index));
  };

  const fetchFrame = async (index: number) => {
    if (disposed || failed || blobs.has(index) || loading.has(index)) return;
    loading.add(index);
    try {
      const response = await fetchImpl(frameUrl(pack, index));
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const blob = await response.blob();
      if (disposed || failed) return;
      blobs.set(index, blob);
      options.onProgress?.(blobs.size, pack.count);
      if (blobs.size >= pack.count && !ready) {
        ready = true;
        options.onReady();
        await present(timeToIndex(target));
      }
    } catch {
      fail();
    } finally {
      loading.delete(index);
    }
  };

  const ensureWindow = (center: number) => {
    const start = Math.max(pack.firstIndex, center - prefetchRadius);
    const end = Math.min(pack.count, center + prefetchRadius);
    const missing: number[] = [];
    for (let index = start; index <= end; index += 1) {
      if (!blobs.has(index) && !loading.has(index)) missing.push(index);
      else if (blobs.has(index) && !bitmaps.has(index)) missing.push(index);
    }
    // Prefer decoding the center first, then neighbors.
    missing.sort(
      (a, b) => Math.abs(a - center) - Math.abs(b - center) || a - b,
    );
    return missing;
  };

  // Kick off full-pack download immediately (gate for onReady).
  loadStartedAt = clock();
  const boot = async () => {
    const batch = 12;
    for (let index = pack.firstIndex; index <= pack.count && !disposed && !failed; ) {
      const slice: Promise<void>[] = [];
      for (let n = 0; n < batch && index <= pack.count; n += 1, index += 1) {
        slice.push(fetchFrame(index));
      }
      await Promise.all(slice);
    }
  };
  void boot();

  return {
    request(time: number) {
      if (!Number.isFinite(time) || disposed || failed) return;
      target = Math.max(0, Math.min(options.duration, time));
    },
    tick(nowSeconds: number) {
      if (disposed || failed) return;
      if (!ready) {
        if (loadStartedAt && nowSeconds - loadStartedAt > 120) fail();
        return;
      }
      const index = timeToIndex(target);
      if (index === presentedIndex && bitmaps.has(index)) {
        stallStartedAt = 0;
        return;
      }
      if (!blobs.has(index)) {
        if (!stallStartedAt) stallStartedAt = nowSeconds;
        else if (nowSeconds - stallStartedAt > 8) fail();
        void fetchFrame(index);
        return;
      }
      stallStartedAt = 0;
      if (decodeInFlight) return;
      decodeInFlight = present(index)
        .then(() => {
          const neighbors = ensureWindow(index);
          for (const neighbor of neighbors.slice(0, 8)) {
            if (!blobs.has(neighbor)) void fetchFrame(neighbor);
            else if (!bitmaps.has(neighbor)) {
              void createBitmap(blobs.get(neighbor)!)
                .then((bitmap) => {
                  if (disposed || failed) {
                    bitmap.close();
                    return;
                  }
                  bitmaps.set(neighbor, bitmap);
                  touchDecoded(neighbor);
                })
                .catch(() => undefined);
            }
          }
        })
        .finally(() => {
          decodeInFlight = null;
        });
    },
    suspend() {
      stallStartedAt = 0;
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
    },
  };
}

/** Pick desktop vs mobile pack from viewport / orientation. */
export function selectFramePack(
  frames: { desktop: FramePack; mobile: FramePack },
  query: { matches: boolean } | null,
): FramePack {
  // Portrait narrow phones use the lighter 12fps pack.
  if (query?.matches) return frames.mobile;
  return frames.desktop;
}

export const MOBILE_FRAME_QUERY = "(orientation: portrait) and (max-width: 900px)";
