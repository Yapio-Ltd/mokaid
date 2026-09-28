/** Scroll-linked frame packs: base TTI + optional desktop densify upgrade. */

export interface FramePack {
  pattern: string;
  firstIndex: number;
  count: number;
  fps: number;
  width: number;
  height: number;
}

export interface FrameControllerOptions {
  /** Bootstrap pack (mobile or desktop base). Ready gates on this pack. */
  pack: FramePack;
  /** Optional denser desktop pack loaded after ready when upgradeEnabled. */
  upgradePack?: FramePack;
  upgradeEnabled?: boolean;
  /** Delay high fetch after base ready (Safari / missing NetInfo idle gate). */
  upgradeDelayMs?: number;
  duration: number;
  canvas: HTMLCanvasElement;
  maxDecoded?: number;
  prefetchRadius?: number;
  maxConcurrent?: number;
  upgradeMaxConcurrent?: number;
  fetchImpl?: typeof fetch;
  createBitmap?: (blob: Blob) => Promise<ImageBitmap>;
  now?: () => number;
  onReady: () => void;
  onPresented: (time: number) => void;
  onError: () => void;
  onProgress?: (loaded: number, total: number) => void;
  onUpgradeActive?: () => void;
}

type PackId = "base" | "high";

interface PackState {
  id: PackId;
  pack: FramePack;
  blobs: Map<number, Blob>;
  bitmaps: Map<number, ImageBitmap>;
  loading: Set<number>;
  queue: number[];
  queued: Set<number>;
  inFlight: number;
  maxConcurrent: number;
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

function timeToIndex(pack: FramePack, duration: number, time: number) {
  const clamped = Math.max(0, Math.min(duration, time));
  const zeroBased = Math.round(clamped * pack.fps);
  return Math.min(pack.count, Math.max(pack.firstIndex, zeroBased + pack.firstIndex));
}

function indexToTime(pack: FramePack, duration: number, index: number) {
  return Math.max(0, Math.min(duration, (index - pack.firstIndex) / pack.fps));
}

/**
 * Ready on first base frame; optional high pack densifies presentation afterward.
 */
export function createCinematicFrameController(options: FrameControllerOptions) {
  const basePack = options.pack;
  const highPack = options.upgradePack;
  const upgradeWanted = Boolean(options.upgradeEnabled && highPack);
  const fetchImpl = options.fetchImpl ?? fetch.bind(globalThis);
  const createBitmap =
    options.createBitmap ?? ((blob: Blob) => createImageBitmap(blob));
  const maxDecoded = options.maxDecoded ?? 48;
  const prefetchRadius = options.prefetchRadius ?? 16;
  const clock = options.now ?? (() => performance.now() / 1000);

  let disposed = false;
  let failed = false;
  let ready = false;
  let upgradeActive = false;
  let target = 0;
  let presented: { id: PackId; index: number } | null = null;
  let decodeInFlight: Promise<void> | null = null;
  let loadStartedAt = 0;
  let upgradeTimer: ReturnType<typeof setTimeout> | null = null;
  const decodeOrder: string[] = [];

  const base: PackState = {
    id: "base",
    pack: basePack,
    blobs: new Map(),
    bitmaps: new Map(),
    loading: new Set(),
    queue: [],
    queued: new Set(),
    inFlight: 0,
    maxConcurrent: options.maxConcurrent ?? (basePack.width <= 640 ? 6 : 10),
  };
  const high: PackState | null =
    highPack && upgradeWanted
      ? {
          id: "high",
          pack: highPack,
          blobs: new Map(),
          bitmaps: new Map(),
          loading: new Set(),
          queue: [],
          queued: new Set(),
          inFlight: 0,
          maxConcurrent: options.upgradeMaxConcurrent ?? 8,
        }
      : null;

  const fail = () => {
    if (disposed || failed) return;
    failed = true;
    options.onError();
  };

  const slotKey = (id: PackId, index: number) => `${id}:${index}`;

  const touchDecoded = (id: PackId, index: number) => {
    const key = slotKey(id, index);
    const at = decodeOrder.indexOf(key);
    if (at >= 0) decodeOrder.splice(at, 1);
    decodeOrder.push(key);
    while (decodeOrder.length > maxDecoded) {
      const evict = decodeOrder.shift();
      if (!evict) break;
      const [packId, indexText] = evict.split(":");
      const store = packId === "high" ? high : base;
      const evictIndex = Number(indexText);
      const bitmap = store?.bitmaps.get(evictIndex);
      if (bitmap) {
        bitmap.close();
        store.bitmaps.delete(evictIndex);
      }
    }
  };

  const resizeCanvas = (pack: FramePack) => {
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

  const nearestLoaded = (store: PackState, wanted: number) => {
    if (store.blobs.has(wanted)) return wanted;
    let best = -1;
    let bestDist = Number.POSITIVE_INFINITY;
    for (const index of store.blobs.keys()) {
      const dist = Math.abs(index - wanted);
      if (dist < bestDist || (dist === bestDist && index < best)) {
        best = index;
        bestDist = dist;
      }
    }
    return best;
  };

  const progressTotal = () => {
    const highCount = high ? high.pack.count : 0;
    return base.pack.count + highCount;
  };

  const progressLoaded = () => base.blobs.size + (high?.blobs.size ?? 0);

  const present = async (store: PackState, index: number) => {
    if (disposed || failed) return;
    let bitmap = store.bitmaps.get(index);
    if (!bitmap) {
      const blob = store.blobs.get(index);
      if (!blob) return;
      try {
        bitmap = await createBitmap(blob);
      } catch {
        if (store.id === "base" && !ready) fail();
        return;
      }
      if (disposed || failed) {
        bitmap.close();
        return;
      }
      store.bitmaps.set(index, bitmap);
      touchDecoded(store.id, index);
    } else {
      touchDecoded(store.id, index);
    }
    const ctx = options.canvas.getContext("2d");
    if (!ctx) {
      fail();
      return;
    }
    const { width, height } = resizeCanvas(store.pack);
    coverDraw(ctx, bitmap, width, height);
    presented = { id: store.id, index };
    if (!ready) {
      ready = true;
      options.onReady();
      if (high) {
        const delay = Math.max(0, options.upgradeDelayMs ?? 0);
        if (delay > 0) {
          upgradeTimer = setTimeout(() => {
            upgradeTimer = null;
            if (!disposed && !failed) startUpgrade();
          }, delay);
        } else {
          startUpgrade();
        }
      }
    }
    if (store.id === "high" && !upgradeActive) {
      upgradeActive = true;
      options.onUpgradeActive?.();
    }
    options.onPresented(indexToTime(store.pack, options.duration, index));
  };

  const pump = (store: PackState) => {
    while (
      store.inFlight < store.maxConcurrent &&
      store.queue.length > 0 &&
      !disposed &&
      !failed
    ) {
      const index = store.queue.shift();
      if (index === undefined) break;
      store.queued.delete(index);
      if (store.blobs.has(index) || store.loading.has(index)) continue;
      store.loading.add(index);
      store.inFlight += 1;
      void (async () => {
        try {
          const response = await fetchImpl(frameUrl(store.pack, index));
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          const blob = await response.blob();
          if (disposed || failed) return;
          store.blobs.set(index, blob);
          options.onProgress?.(progressLoaded(), progressTotal());
          const wanted = timeToIndex(store.pack, options.duration, target);
          if (store.id === "base") {
            if (index === wanted || (!ready && index === store.pack.firstIndex)) {
              await present(store, index);
            } else if (ready && !store.blobs.has(wanted)) {
              const near = nearestLoaded(store, wanted);
              if (near === index) await present(store, index);
            }
          } else if (ready) {
            // Prefer high once available near the playhead.
            const near = nearestLoaded(store, wanted);
            if (near === index && Math.abs(index - wanted) <= prefetchRadius) {
              await present(store, index);
            }
          }
        } catch {
          if (store.id === "base" && !ready && index === store.pack.firstIndex) fail();
        } finally {
          store.loading.delete(index);
          store.inFlight -= 1;
          if (!disposed && !failed) pump(store);
        }
      })();
    }
  };

  const enqueue = (store: PackState, index: number, priority: "front" | "back" = "back") => {
    if (
      disposed ||
      failed ||
      index < store.pack.firstIndex ||
      index > store.pack.count ||
      store.blobs.has(index) ||
      store.loading.has(index) ||
      store.queued.has(index)
    ) {
      return;
    }
    store.queued.add(index);
    if (priority === "front") store.queue.unshift(index);
    else store.queue.push(index);
    pump(store);
  };

  const ensureWindow = (store: PackState, center: number) => {
    const start = Math.max(store.pack.firstIndex, center - prefetchRadius);
    const end = Math.min(store.pack.count, center + prefetchRadius);
    const neighbors: number[] = [];
    for (let index = start; index <= end; index += 1) neighbors.push(index);
    neighbors.sort((a, b) => Math.abs(a - center) - Math.abs(b - center) || a - b);
    for (const index of neighbors) enqueue(store, index, "front");
  };

  const fillBackground = (store: PackState) => {
    const center = timeToIndex(store.pack, options.duration, target);
    const rest: number[] = [];
    for (let index = store.pack.firstIndex; index <= store.pack.count; index += 1) {
      if (!store.blobs.has(index) && !store.loading.has(index) && !store.queued.has(index)) {
        rest.push(index);
      }
    }
    rest.sort((a, b) => Math.abs(a - center) - Math.abs(b - center) || a - b);
    for (const index of rest) enqueue(store, index, "back");
  };

  const startUpgrade = () => {
    if (!high) return;
    const center = timeToIndex(high.pack, options.duration, target);
    enqueue(high, center, "front");
    ensureWindow(high, center);
    fillBackground(high);
  };

  const pickPresentable = (): { store: PackState; index: number } | null => {
    if (high && high.blobs.size > 0) {
      const wantedHigh = timeToIndex(high.pack, options.duration, target);
      const nearHigh = nearestLoaded(high, wantedHigh);
      if (nearHigh >= 0) {
        const highTime = indexToTime(high.pack, options.duration, nearHigh);
        // Use high when within half a base-frame of the target time.
        if (Math.abs(highTime - target) <= 0.5 / Math.max(1, base.pack.fps) + 1 / high.pack.fps) {
          return { store: high, index: nearHigh };
        }
        // Or when high is simply closer in time than base nearest.
        const wantedBase = timeToIndex(base.pack, options.duration, target);
        const nearBase = nearestLoaded(base, wantedBase);
        if (nearBase < 0) return { store: high, index: nearHigh };
        const baseTime = indexToTime(base.pack, options.duration, nearBase);
        if (Math.abs(highTime - target) <= Math.abs(baseTime - target)) {
          return { store: high, index: nearHigh };
        }
      }
    }
    const wantedBase = timeToIndex(base.pack, options.duration, target);
    const nearBase = blobsNearestOrWanted(base, wantedBase);
    if (nearBase < 0) return null;
    return { store: base, index: nearBase };
  };

  const blobsNearestOrWanted = (store: PackState, wanted: number) =>
    store.blobs.has(wanted) ? wanted : nearestLoaded(store, wanted);

  loadStartedAt = clock();
  enqueue(base, base.pack.firstIndex, "front");
  ensureWindow(base, base.pack.firstIndex);
  fillBackground(base);

  return {
    request(time: number) {
      if (!Number.isFinite(time) || disposed || failed) return;
      target = Math.max(0, Math.min(options.duration, time));
      const baseIndex = timeToIndex(base.pack, options.duration, target);
      enqueue(base, baseIndex, "front");
      ensureWindow(base, baseIndex);
      if (high && ready) {
        const highIndex = timeToIndex(high.pack, options.duration, target);
        enqueue(high, highIndex, "front");
        ensureWindow(high, highIndex);
      }
    },
    tick(nowSeconds: number) {
      if (disposed || failed) return;
      if (!ready) {
        if (loadStartedAt && nowSeconds - loadStartedAt > 8) fail();
        return;
      }
      const pick = pickPresentable();
      if (!pick) {
        enqueue(base, timeToIndex(base.pack, options.duration, target), "front");
        return;
      }
      if (
        presented &&
        presented.id === pick.store.id &&
        presented.index === pick.index &&
        pick.store.bitmaps.has(pick.index)
      ) {
        if (high) ensureWindow(high, timeToIndex(high.pack, options.duration, target));
        return;
      }
      if (decodeInFlight) return;
      decodeInFlight = present(pick.store, pick.index)
        .then(() => {
          ensureWindow(base, timeToIndex(base.pack, options.duration, target));
          if (high) ensureWindow(high, timeToIndex(high.pack, options.duration, target));
        })
        .finally(() => {
          decodeInFlight = null;
        });
    },
    suspend() {
      loadStartedAt = clock();
    },
    redraw() {
      if (presented) {
        const store = presented.id === "high" && high ? high : base;
        void present(store, presented.index);
      }
    },
    dispose() {
      disposed = true;
      if (upgradeTimer) {
        clearTimeout(upgradeTimer);
        upgradeTimer = null;
      }
      for (const store of [base, high]) {
        if (!store) continue;
        for (const bitmap of store.bitmaps.values()) bitmap.close();
        store.bitmaps.clear();
        store.blobs.clear();
        store.queue.length = 0;
        store.queued.clear();
        store.loading.clear();
      }
      decodeOrder.length = 0;
    },
  };
}

export interface StoryFramesManifest {
  desktop: FramePack | { base: FramePack; high?: FramePack };
  mobile: FramePack;
}

/** Normalize legacy flat desktop pack or { base, high } tiers. */
export function desktopBasePack(frames: StoryFramesManifest): FramePack {
  const desktop = frames.desktop;
  if ("base" in desktop) return desktop.base;
  return desktop;
}

export function desktopHighPack(frames: StoryFramesManifest): FramePack | undefined {
  const desktop = frames.desktop;
  if ("base" in desktop) return desktop.high;
  return undefined;
}

/** Pick mobile pack or desktop base from viewport / orientation. */
export function selectFramePack(
  frames: StoryFramesManifest,
  query: { matches: boolean } | null,
): FramePack {
  if (query?.matches) return frames.mobile;
  return desktopBasePack(frames);
}

export const MOBILE_FRAME_QUERY = "(orientation: portrait) and (max-width: 900px)";
