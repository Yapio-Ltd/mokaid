import { afterEach, describe, expect, it, vi } from "vitest";
import { cinematicStory, cueAtTime, storyTimeAtProgress } from "@/data/cinematic-story";
import {
  createCinematicFrameController,
  selectFramePack,
  type FramePack,
} from "@/lib/cinematic-frame-controller";

const pack: FramePack = {
  pattern: "/frames/frame-%05d.webp",
  firstIndex: 1,
  count: 24,
  fps: 12,
  width: 96,
  height: 54,
};

function fakeBitmap(label: number): ImageBitmap {
  return {
    width: pack.width,
    height: pack.height,
    close: vi.fn(),
    label,
  } as unknown as ImageBitmap;
}

function setup(
  overrides: Partial<Parameters<typeof createCinematicFrameController>[0]> = {},
  options: { available?: number[] } = {},
) {
  const draws: number[] = [];
  const canvas = {
    clientWidth: 390,
    clientHeight: 844,
    width: 0,
    height: 0,
    getContext: () => ({
      clearRect: vi.fn(),
      drawImage: (_bitmap: ImageBitmap, ..._rest: number[]) => {
        draws.push((_bitmap as unknown as { label: number }).label);
      },
    }),
  } as unknown as HTMLCanvasElement;

  const available = new Set(options.available ?? Array.from({ length: pack.count }, (_, i) => i + 1));
  const blobs = new Map<string, Blob>();
  for (const index of available) {
    blobs.set(
      pack.pattern.replace("%05d", String(index).padStart(5, "0")),
      new Blob([`frame-${index}`], { type: "image/webp" }),
    );
  }

  const fetchImpl = vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input);
    const blob = blobs.get(url);
    if (!blob) return new Response(null, { status: 404 });
    return new Response(blob, { status: 200 });
  });

  const createBitmap = vi.fn(async (blob: Blob) => {
    const text = await blob.text();
    const index = Number(text.replace("frame-", ""));
    return fakeBitmap(index);
  });

  const onReady = vi.fn();
  const onPresented = vi.fn();
  const onError = vi.fn();
  const onProgress = vi.fn();

  const controller = createCinematicFrameController({
    pack,
    duration: 2,
    canvas,
    maxDecoded: 4,
    prefetchRadius: 2,
    maxConcurrent: 4,
    fetchImpl: fetchImpl as unknown as typeof fetch,
    createBitmap,
    now: () => 0,
    onReady,
    onPresented,
    onError,
    onProgress,
    ...overrides,
  });

  return { controller, onReady, onPresented, onError, onProgress, fetchImpl, createBitmap, draws };
}

async function flush() {
  for (let i = 0; i < 40; i += 1) await Promise.resolve();
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("cinematic story mapping", () => {
  it("preserves every authored milestone and reverses without hysteresis", () => {
    for (const point of cinematicStory.scrollMap) {
      expect(storyTimeAtProgress(point.progress)).toBeCloseTo(point.time, 8);
    }
    const forward = Array.from({ length: 101 }, (_, index) => storyTimeAtProgress(index / 100));
    const backward = Array.from({ length: 101 }, (_, index) =>
      storyTimeAtProgress((100 - index) / 100),
    );
    expect(backward.reverse()).toEqual(forward);
  });

  it("leaves the portal and exit free of captions and holds the final CTA", () => {
    for (const time of [13, 15, 17.49, 61, 65, 66.99]) expect(cueAtTime(time)).toBeUndefined();
    expect(cueAtTime(18)?.id).toBe("enter");
    expect(cueAtTime(73.99)?.cta).toBe(true);
  });
});

describe("frame pack selection", () => {
  it("uses the mobile pack on portrait narrow viewports", () => {
    expect(selectFramePack(cinematicStory.frames, { matches: true })).toBe(
      cinematicStory.frames.mobile,
    );
    expect(selectFramePack(cinematicStory.frames, { matches: false })).toEqual(
      "base" in cinematicStory.frames.desktop
        ? cinematicStory.frames.desktop.base
        : cinematicStory.frames.desktop,
    );
  });
});

describe("desktop densify upgrade", () => {
  const highPack: FramePack = {
    pattern: "/high/frame-%05d.webp",
    firstIndex: 1,
    count: 24,
    fps: 24,
    width: 128,
    height: 72,
  };

  it("becomes ready on base before high finishes, then densifies", async () => {
    const highBlobs = new Map<string, Blob>();
    for (let index = 1; index <= highPack.count; index += 1) {
      highBlobs.set(
        highPack.pattern.replace("%05d", String(index).padStart(5, "0")),
        new Blob([`high-${index}`], { type: "image/webp" }),
      );
    }
    const onUpgradeActive = vi.fn();
    const onReady = vi.fn();
    const createBitmap = vi.fn(async (blob: Blob) => {
      const text = await blob.text();
      const label = text.startsWith("high-")
        ? Number(text.replace("high-", "")) + 1000
        : Number(text.replace("frame-", ""));
      return fakeBitmap(label);
    });
    // Gate high responses so base can ready before densify starts presenting.
    let releaseHigh = false;
    const pendingHigh: Array<() => void> = [];
    const fetchImpl = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes("/high/")) {
        if (!releaseHigh) {
          await new Promise<void>((resolve) => pendingHigh.push(resolve));
        }
        const blob = highBlobs.get(url);
        if (!blob) return new Response(null, { status: 404 });
        return new Response(blob, { status: 200 });
      }
      const baseBlob = new Blob(
        [`frame-${Number(url.match(/frame-(\d+)/)?.[1] ?? "0")}`],
        { type: "image/webp" },
      );
      return new Response(baseBlob, { status: 200 });
    });
    const { controller, onPresented } = setup({
      onReady,
      onUpgradeActive,
      upgradePack: highPack,
      upgradeEnabled: true,
      createBitmap,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      prefetchRadius: 1,
      maxConcurrent: 2,
      upgradeMaxConcurrent: 2,
    });
    await vi.waitFor(() => expect(onReady).toHaveBeenCalledOnce());
    expect(onUpgradeActive).not.toHaveBeenCalled();
    expect(fetchImpl.mock.calls.some((call) => String(call[0]).includes("/high/"))).toBe(true);
    releaseHigh = true;
    for (const resolve of pendingHigh.splice(0)) resolve();
    controller.request(1);
    for (let i = 0; i < 30; i += 1) {
      controller.tick(i + 1);
      await flush();
    }
    await vi.waitFor(() => expect(onUpgradeActive).toHaveBeenCalled());
    expect(onPresented.mock.calls.length).toBeGreaterThan(0);
    controller.dispose();
  });

  it("does not fetch high when upgrade is disabled (saveData / slow)", async () => {
    const { controller, onReady, fetchImpl } = setup({
      upgradePack: highPack,
      upgradeEnabled: false,
    });
    await vi.waitFor(() => expect(onReady).toHaveBeenCalledOnce());
    await flush();
    expect(fetchImpl.mock.calls.every((call) => !String(call[0]).includes("/high/"))).toBe(true);
    controller.dispose();
  });
});

describe("cinematic frame controller", () => {
  it("becomes ready on the first frame without waiting for the full pack", async () => {
    let loadedAtReady = 0;
    const onProgress = vi.fn();
    const onReady = vi.fn(() => {
      loadedAtReady = (onProgress.mock.calls.at(-1)?.[0] as number) ?? 0;
    });
    // Delay non-first frames so readiness cannot wait on the full pack.
    const base = setup({ onReady, onProgress });
    const originalFetch = base.fetchImpl.getMockImplementation()!;
    base.fetchImpl.mockImplementation(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (!url.endsWith("frame-00001.webp")) {
        await new Promise((resolve) => setTimeout(resolve, 30));
      }
      return originalFetch(input);
    });
    await vi.waitFor(() => expect(onReady).toHaveBeenCalledOnce());
    expect(loadedAtReady).toBeGreaterThanOrEqual(1);
    expect(loadedAtReady).toBeLessThan(pack.count);
    base.controller.dispose();
  });

  it("coalesces rapid scroll targets to the latest frame", async () => {
    const { controller, onReady, onPresented } = setup();
    await vi.waitFor(() => expect(onReady).toHaveBeenCalledOnce());
    controller.request(0.2);
    controller.request(1.5);
    controller.tick(1);
    await vi.waitFor(() =>
      expect(onPresented.mock.calls.at(-1)?.[0]).toBeCloseTo(1.5, 5),
    );
    controller.dispose();
  });

  it("holds the nearest loaded frame when the exact target is missing", async () => {
    const available = Array.from({ length: 12 }, (_, i) => i * 2 + 1);
    const { controller, onReady, onPresented, onError } = setup(
      { maxConcurrent: 2, prefetchRadius: 1 },
      { available },
    );
    await vi.waitFor(() => expect(onReady).toHaveBeenCalledOnce());
    controller.request(0.25);
    controller.tick(1);
    await flush();
    expect(onError).not.toHaveBeenCalled();
    expect(onPresented.mock.calls.length).toBeGreaterThan(0);
    controller.dispose();
  });

  it("evicts decoded bitmaps beyond the LRU budget", async () => {
    const closes: Array<ReturnType<typeof vi.fn>> = [];
    const createBitmap = vi.fn(async (blob: Blob) => {
      const text = await blob.text();
      const index = Number(text.replace("frame-", ""));
      const close = vi.fn();
      closes.push(close);
      return { width: 96, height: 54, close, label: index } as unknown as ImageBitmap;
    });
    const { controller, onReady } = setup({ createBitmap, maxDecoded: 3, prefetchRadius: 1 });
    await vi.waitFor(() => expect(onReady).toHaveBeenCalledOnce());
    for (const time of [0, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75]) {
      controller.request(time);
      controller.tick(time + 1);
      await flush();
    }
    expect(closes.some((close) => close.mock.calls.length > 0)).toBe(true);
    controller.dispose();
  });

  it("reports hard failure when the first frame cannot load", async () => {
    const { controller, onError } = setup({
      fetchImpl: vi.fn(async () => new Response(null, { status: 500 })) as unknown as typeof fetch,
    });
    await vi.waitFor(() => expect(onError).toHaveBeenCalledOnce());
    controller.dispose();
  });

  it("does not treat a suspended tab as a stall timeout", async () => {
    const { controller, onReady, onError } = setup();
    await vi.waitFor(() => expect(onReady).toHaveBeenCalledOnce());
    controller.request(1);
    controller.tick(1);
    controller.suspend();
    controller.tick(40);
    expect(onError).not.toHaveBeenCalled();
    controller.dispose();
  });
});
