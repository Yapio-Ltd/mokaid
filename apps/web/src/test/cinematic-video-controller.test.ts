import { describe, expect, it, vi } from "vitest";
import { cinematicStory, cueAtTime, storyTimeAtProgress } from "@/data/cinematic-story";
import {
  createCinematicVideoController,
  type CinematicMedia,
} from "@/lib/cinematic-video-controller";

class FakeMedia extends EventTarget implements CinematicMedia {
  duration = 74;
  readyState = 0;
  seeking = false;
  paused = true;
  private time = 0;
  seeks: number[] = [];
  pause = vi.fn(() => {
    this.paused = true;
  });
  requestVideoFrameCallback?: CinematicMedia["requestVideoFrameCallback"];
  cancelVideoFrameCallback = vi.fn();

  get currentTime() {
    return this.time;
  }
  set currentTime(time: number) {
    this.seeks.push(time);
    this.time = time;
    this.seeking = true;
  }
  loadFrame() {
    this.readyState = 2;
    this.dispatchEvent(new Event("loadeddata"));
  }
  finishSeek() {
    this.seeking = false;
    this.dispatchEvent(new Event("seeked"));
  }
}

function setup(media = new FakeMedia()) {
  const onReady = vi.fn();
  const onPresented = vi.fn();
  const onError = vi.fn();
  const controller = createCinematicVideoController(media, {
    duration: 74,
    fps: 24,
    onReady,
    onPresented,
    onError,
  });
  return { media, controller, onReady, onPresented, onError };
}

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
    expect(forward.every((time, index) => index === 0 || time > forward[index - 1])).toBe(true);
  });

  it("clamps invalid/out-of-range positions without NaN seeks", () => {
    expect(storyTimeAtProgress(-1)).toBe(0);
    expect(storyTimeAtProgress(2)).toBe(74);
    expect(storyTimeAtProgress(Number.NaN)).toBe(0);
  });

  it("leaves the portal and exit free of captions and holds the final CTA", () => {
    for (const time of [13, 15, 17.49, 61, 65, 66.99]) expect(cueAtTime(time)).toBeUndefined();
    expect(cueAtTime(18)?.id).toBe("enter");
    expect(cueAtTime(73.99)?.cta).toBe(true);
    expect(cueAtTime(74)?.cta).toBe(true);
    expect(cueAtTime(75)).toBeUndefined();
  });
});

describe("paused cinematic media controller", () => {
  it("waits for a decoded frame, then coalesces pending scroll to the latest target", () => {
    const { media, controller, onReady } = setup();
    controller.request(7);
    controller.tick(0);
    expect(media.seeks).toEqual([]);
    media.loadFrame();
    expect(onReady).toHaveBeenCalledOnce();
    controller.tick(1);
    controller.request(18);
    controller.request(55);
    controller.tick(1.1);
    expect(media.seeks).toEqual([7]);
    media.finishSeek();
    controller.tick(1.2);
    expect(media.seeks).toEqual([7, 55]);
    controller.dispose();
  });

  it("reverses and stops at the last decodable frame, with no redundant same-frame seeks", () => {
    const { media, controller } = setup();
    media.loadFrame();
    controller.request(74);
    controller.tick(1);
    expect(media.seeks[0]).toBeCloseTo(74 - 1 / 24);
    media.finishSeek();
    controller.request(20);
    controller.tick(2);
    media.finishSeek();
    controller.request(20.001);
    controller.tick(3);
    expect(media.seeks).toHaveLength(2);
    controller.request(0);
    controller.tick(4);
    expect(media.seeks[2]).toBe(0);
    controller.dispose();
  });

  it("synchronizes captions to presented frames rather than requested times", () => {
    const media = new FakeMedia();
    let present: ((now: number, metadata: { mediaTime: number }) => void) | undefined;
    media.requestVideoFrameCallback = vi.fn((callback) => {
      present = callback;
      return 17;
    });
    const { controller, onPresented, onReady } = setup(media);
    media.loadFrame();
    expect(onReady).toHaveBeenCalledOnce();
    expect(onPresented).not.toHaveBeenCalled();
    present?.(0, { mediaTime: 0 });
    expect(onReady).toHaveBeenCalledOnce();
    onPresented.mockClear();
    controller.request(55);
    controller.tick(1);
    media.finishSeek();
    expect(onPresented).not.toHaveBeenCalled();
    present?.(1000, { mediaTime: 54.9583 });
    expect(onPresented).toHaveBeenLastCalledWith(54.9583);
    controller.dispose();
    expect(media.cancelVideoFrameCallback).toHaveBeenCalledWith(17);
  });

  it("rejects a partial film and stops attempting work after errors or cleanup", () => {
    const { media, controller, onError, onReady } = setup();
    media.duration = 8;
    media.loadFrame();
    expect(onError).toHaveBeenCalledOnce();
    expect(onReady).not.toHaveBeenCalled();
    controller.request(20);
    controller.tick(1);
    expect(media.seeks).toEqual([]);
    controller.dispose();
    media.dispatchEvent(new Event("error"));
    expect(onError).toHaveBeenCalledOnce();
  });

  it("reports a stuck decoder instead of blocking the experience indefinitely", () => {
    const { media, controller, onError } = setup();
    media.loadFrame();
    controller.request(36);
    controller.tick(1);
    controller.tick(10);
    expect(onError).toHaveBeenCalledOnce();
    controller.dispose();
  });

  it("starts from decoded data while the rest of the timeline is still loading", () => {
    const media = new FakeMedia() as FakeMedia & { seekable: TimeRanges };
    media.seekable = { length: 1, start: () => 0, end: () => 2 };
    const { controller, onReady } = setup(media);
    media.loadFrame();
    expect(onReady).toHaveBeenCalledOnce();
    controller.request(55);
    controller.tick(1);
    expect(media.seeks).toEqual([55]);
    media.seekable = { length: 1, start: () => 0, end: () => 74 };
    media.dispatchEvent(new Event("progress"));
    expect(onReady).toHaveBeenCalledOnce();
    controller.dispose();
  });

  it("requests a first frame when a mobile browser preloads metadata only", () => {
    const media = new FakeMedia() as FakeMedia & { seekable: TimeRanges };
    media.seekable = { length: 0, start: () => 0, end: () => 0 };
    const { controller, onReady, onPresented } = setup(media);
    media.readyState = 1;
    media.dispatchEvent(new Event("loadedmetadata"));
    controller.tick(1);
    expect(media.seeks).toEqual([]);
    expect(onReady).not.toHaveBeenCalled();
    media.seekable = { length: 1, start: () => 0, end: () => 74 };
    controller.tick(2);
    expect(media.seeks).toEqual([1 / 24]);
    expect(onPresented).not.toHaveBeenCalled();
    media.loadFrame();
    media.finishSeek();
    expect(onReady).toHaveBeenCalledOnce();
    controller.tick(3);
    expect(media.seeks).toEqual([1 / 24, 0]);
    controller.dispose();
  });

  it("uses a restored scroll position for the first metadata-only seek", () => {
    const { media, controller, onReady, onPresented } = setup();
    media.readyState = 1;
    media.dispatchEvent(new Event("loadedmetadata"));
    controller.request(40);
    controller.tick(1);
    expect(media.seeks).toEqual([40]);
    expect(onReady).not.toHaveBeenCalled();
    expect(onPresented).not.toHaveBeenCalled();
    media.loadFrame();
    media.finishSeek();
    expect(onReady).toHaveBeenCalledOnce();
    expect(onPresented).toHaveBeenLastCalledWith(40);
    controller.dispose();
  });

  it("retries a synchronously aborted seek without reporting a decoder timeout", () => {
    const { media, controller, onError } = setup();
    media.loadFrame();
    vi.spyOn(media, "currentTime", "set").mockImplementationOnce((time) => {
      media.seeks.push(time);
    });
    controller.request(36);
    controller.tick(1);
    controller.tick(10);
    expect(media.seeks).toEqual([36, 36]);
    expect(onError).not.toHaveBeenCalled();
    media.finishSeek();
    controller.dispose();
  });

  it("does not treat a suspended background tab as a decoder timeout", () => {
    const { media, controller, onError } = setup();
    media.loadFrame();
    controller.request(36);
    controller.tick(1);
    controller.suspend();
    controller.tick(40);
    expect(onError).not.toHaveBeenCalled();
    media.finishSeek();
    controller.dispose();
  });
});
