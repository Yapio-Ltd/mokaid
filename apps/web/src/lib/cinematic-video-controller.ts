/** The small media surface keeps seeking behavior testable without a browser decoder. */
export interface CinematicMedia {
  currentTime: number;
  duration: number;
  readyState: number;
  seeking: boolean;
  paused: boolean;
  seekable?: Pick<TimeRanges, "length" | "start" | "end">;
  pause(): void;
  addEventListener(type: string, listener: EventListener): void;
  removeEventListener(type: string, listener: EventListener): void;
  requestVideoFrameCallback?: (
    callback: (now: number, metadata: { mediaTime: number }) => void,
  ) => number;
  cancelVideoFrameCallback?: (id: number) => void;
}

interface VideoControllerOptions {
  duration: number;
  fps: number;
  onReady: () => void;
  onPresented: (time: number) => void;
  onError: () => void;
}

/**
 * A paused video, one seek in flight, and one replaceable target.
 * tick() belongs to the existing GSAP ticker, never a second RAF loop.
 */
export function createCinematicVideoController(
  media: CinematicMedia,
  options: VideoControllerOptions,
) {
  let disposed = false;
  let ready = false;
  let failed = false;
  let inFlight = false;
  let target = 0;
  let frameId: number | undefined;
  let seekStartedAt = 0;
  const frameDuration = 1 / options.fps;
  const listeners: [string, EventListener][] = [];

  const fail = () => {
    if (disposed || failed) return;
    failed = true;
    options.onError();
  };

  const present = (time: number) => {
    if (!disposed && !failed && Number.isFinite(time)) {
      options.onPresented(Math.max(0, Math.min(options.duration, time)));
    }
  };

  const inspectReadiness = () => {
    if (disposed || failed || ready || media.readyState < 1) return;
    // A partial or wrong film must not silently stretch across the authored story.
    if (!Number.isFinite(media.duration) || Math.abs(media.duration - options.duration) > 0.25) {
      fail();
      return;
    }
    // A paused/offscreen video may defer its frame callback. Decoded current
    // data is enough to start; seeking can fetch the rest of the film on demand.
    if (media.readyState < 2) return;
    ready = true;
    media.pause();
    if (!media.requestVideoFrameCallback) present(media.currentTime);
    options.onReady();
  };

  const watchPresentedFrames = () => {
    if (disposed || failed || !media.requestVideoFrameCallback) return;
    frameId = media.requestVideoFrameCallback((_now, metadata) => {
      present(metadata.mediaTime);
      inspectReadiness();
      watchPresentedFrames();
    });
  };

  const onSeeked = () => {
    inFlight = false;
    // currentTime is the completed seek only on engines without frame callbacks.
    if (!media.requestVideoFrameCallback && media.readyState >= 2) present(media.currentTime);
    inspectReadiness();
  };

  const listen = (event: string, listener: EventListener) => {
    listeners.push([event, listener]);
    media.addEventListener(event, listener);
  };
  listen("loadedmetadata", inspectReadiness);
  listen("loadeddata", inspectReadiness);
  listen("canplay", inspectReadiness);
  listen("progress", inspectReadiness);
  listen("seeked", onSeeked);
  listen("error", fail);
  // Unexpected autoplay must never make the scroll-linked movie drift.
  listen("play", () => media.pause());
  watchPresentedFrames();
  inspectReadiness();

  return {
    request(time: number) {
      if (!Number.isFinite(time) || disposed || failed) return;
      target = Math.max(0, Math.min(options.duration - frameDuration, time));
    },
    tick(nowSeconds: number) {
      if (disposed || failed) return;
      inspectReadiness();
      if (failed || media.readyState < 1) return;
      if (!media.paused) media.pause();
      // A failed decoder should expose the escape/CTA instead of waiting forever.
      if (inFlight && seekStartedAt === 0) seekStartedAt = nowSeconds;
      if (inFlight && nowSeconds - seekStartedAt > 8) {
        fail();
        return;
      }
      if (inFlight || media.seeking) return;
      // Mobile browsers may preload metadata only. Once a range exists, a
      // paused seek requests an actual frame without requiring autoplay.
      if (!ready && media.seekable?.length === 0) return;
      const seekTarget = !ready ? Math.max(frameDuration, target) : target;
      if (Math.abs(media.currentTime - seekTarget) < frameDuration / 2) return;
      inFlight = true;
      seekStartedAt = nowSeconds;
      try {
        media.currentTime = seekTarget;
        // An unavailable range can make the browser abort synchronously.
        // Keep the requested target pending instead of timing out a non-seek.
        if (!media.seeking) inFlight = false;
      } catch {
        fail();
      }
    },
    suspend() {
      // Background tab time is not evidence of a decoder failure.
      seekStartedAt = 0;
    },
    dispose() {
      disposed = true;
      listeners.forEach(([event, listener]) => media.removeEventListener(event, listener));
      if (frameId !== undefined) media.cancelVideoFrameCallback?.(frameId);
      media.pause();
    },
  };
}
