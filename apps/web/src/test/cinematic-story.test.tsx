import { StrictMode } from "react";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CinematicStory } from "@/components/landing/cinematic-story";
import { cinematicStory, storyTimeAtProgress } from "@/data/cinematic-story";

const mocks = vi.hoisted(() => ({
  tickerAdd: vi.fn(),
  tickerRemove: vi.fn(),
  triggerKill: vi.fn(),
  triggerCreate: vi.fn(),
  refresh: vi.fn(),
}));
vi.mock("gsap", () => ({
  default: {
    registerPlugin: vi.fn(),
    ticker: { add: mocks.tickerAdd, remove: mocks.tickerRemove },
  },
}));
vi.mock("gsap/ScrollTrigger", () => ({
  ScrollTrigger: { create: mocks.triggerCreate, refresh: mocks.refresh },
}));

let top = 2000;
let readyState = 0;
let eligible = true;
let progress = 0;
let query: EventTarget & { matches: boolean; media: string };

beforeEach(() => {
  top = 2000;
  readyState = 0;
  eligible = true;
  progress = 0;
  query = Object.assign(new EventTarget(), {
    matches: true,
    media: "(prefers-reduced-motion: no-preference)",
  });
  vi.stubGlobal(
    "matchMedia",
    vi.fn(() => {
      query.matches = eligible;
      return query;
    }),
  );
  mocks.triggerCreate.mockImplementation(() => ({
    progress,
    kill: mocks.triggerKill,
  }));
  vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(() => ({
    top,
    bottom: top + 1500,
    left: 0,
    right: 1440,
    width: 1440,
    height: 1500,
    x: 0,
    y: top,
    toJSON: () => ({}),
  }));
  vi.spyOn(HTMLMediaElement.prototype, "load").mockImplementation(() => undefined);
  vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(() => undefined);
  vi.spyOn(HTMLMediaElement.prototype, "duration", "get").mockReturnValue(74);
  vi.spyOn(HTMLMediaElement.prototype, "seekable", "get").mockReturnValue({
    length: 1,
    start: () => 0,
    end: () => 74,
  });
  vi.spyOn(HTMLMediaElement.prototype, "readyState", "get").mockImplementation(() => readyState);
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

function decode(video: HTMLVideoElement) {
  readyState = 2;
  fireEvent.loadedData(video);
}

function tick() {
  act(() => mocks.tickerAdd.mock.calls.at(-1)![0](1));
}

describe("cinematic story lifecycle", () => {
  it("keeps reduced-motion content readable and source-free", () => {
    eligible = false;
    const { container } = render(<CinematicStory />);
    expect(container.querySelector("video")).toBeNull();
    expect(screen.getAllByRole("img")).toHaveLength(3);
    expect(screen.getByRole("link", { name: /Build your team/ })).toHaveAttribute(
      "href",
      "/download",
    );
    expect(screen.getByRole("heading", { name: "Enter your AI office." })).toBeVisible();
  });

  it("keeps prerendered content static, semantic and source-free", () => {
    vi.stubGlobal("__MOKAID_PRERENDER__", true);
    const { container } = render(<CinematicStory />);
    expect(container.querySelector("video")).toBeNull();
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "static");
    expect(
      screen.getByRole("heading", { name: "Your AI employees are already at work." }),
    ).toBeVisible();
  });

  it.each([390, 768, 1024, 1440])("loads the complete video at viewport width %i", (width) => {
    vi.stubGlobal("innerWidth", width);
    const { container, unmount } = render(<CinematicStory />);
    const video = container.querySelector("video")!;
    expect(window.matchMedia).toHaveBeenCalledWith("(prefers-reduced-motion: no-preference)");
    expect(video).toHaveAttribute("src", cinematicStory.video);
    expect(video.muted).toBe(true);
    expect(video).toHaveAttribute("playsinline");
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "loading");
    expect(mocks.tickerAdd).toHaveBeenCalledOnce();
    expect(screen.getByRole("link", { name: /Skip the tour/ })).toHaveAttribute("tabindex", "0");
    decode(video);
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "cinematic");
    expect(container.querySelector("#product")).toHaveAttribute("data-video-ready", "true");
    expect(mocks.tickerAdd).toHaveBeenCalledOnce();
    unmount();
    expect(mocks.tickerRemove).toHaveBeenCalledOnce();
    expect(mocks.triggerKill).toHaveBeenCalledOnce();
    expect(video).not.toHaveAttribute("src");
  });

  it("finishes loading after early entry and more than the old 12-second cutoff", () => {
    vi.useFakeTimers();
    const { container } = render(<CinematicStory />);
    const video = container.querySelector("video")!;
    top = 200;
    fireEvent.scroll(window);
    act(() => vi.advanceTimersByTime(20_000));
    expect(container.querySelector("video")).toBe(video);
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "loading");
    expect(screen.getByRole("button", { name: "Retry the tour" })).toBeVisible();
    decode(video);
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "cinematic");
    expect(screen.queryByRole("button", { name: "Retry the tour" })).toBeNull();
  });

  it("can retry a stalled request even when the browser never reports an error", () => {
    vi.useFakeTimers();
    progress = 0.57;
    const { container } = render(<CinematicStory />);
    const video = container.querySelector("video")!;
    const initialLoads = vi.mocked(video.load).mock.calls.length;
    act(() => vi.advanceTimersByTime(12_000));
    fireEvent.click(screen.getByRole("button", { name: "Retry the tour" }));
    expect(vi.mocked(video.load).mock.calls.length).toBeGreaterThan(initialLoads);
    expect(screen.queryByRole("button", { name: "Retry the tour" })).toBeNull();
    decode(video);
    tick();
    expect(video.currentTime).toBe(42);
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "cinematic");
  });

  it("loads on a restored mid-story visit and seeks to the restored scroll progress", () => {
    top = -200;
    progress = 0.57;
    const { container } = render(<CinematicStory />);
    const video = container.querySelector("video")!;
    decode(video);
    tick();
    expect(video.currentTime).toBe(storyTimeAtProgress(progress));
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "cinematic");
  });

  it("reinitializes video and scroll ownership after leaving and returning to the page", () => {
    const first = render(<CinematicStory />);
    const oldVideo = first.container.querySelector("video")!;
    decode(oldVideo);
    first.unmount();
    readyState = 0;
    top = -300;
    progress = 0.43;
    const second = render(<CinematicStory />);
    const newVideo = second.container.querySelector("video")!;
    expect(newVideo).not.toBe(oldVideo);
    expect(oldVideo).not.toHaveAttribute("src");
    decode(newVideo);
    tick();
    expect(newVideo.currentTime).toBe(32);
    expect(mocks.tickerAdd).toHaveBeenCalledTimes(2);
    expect(mocks.tickerRemove).toHaveBeenCalledOnce();
  });

  it("does not lock out the video while initial CSS is pending", () => {
    vi.spyOn(document, "readyState", "get").mockReturnValue("interactive");
    const stylesheet = document.createElement("link");
    stylesheet.rel = "stylesheet";
    stylesheet.href = "/pending-layout.css";
    document.head.append(stylesheet);
    try {
      top = 200;
      const { container } = render(<CinematicStory />);
      const video = container.querySelector("video")!;
      expect(video).toHaveAttribute("src", cinematicStory.video);
      fireEvent.load(stylesheet);
      fireEvent.load(window);
      decode(video);
      expect(container.querySelector("#product")).toHaveAttribute("data-mode", "cinematic");
    } finally {
      stylesheet.remove();
    }
  });

  it("allows retrying a failed load at the current scroll position", () => {
    progress = 0.69;
    const { container } = render(<CinematicStory />);
    const video = container.querySelector("video")!;
    fireEvent.error(video);
    expect(container.querySelector("video")).toBe(video);
    expect(container.querySelector("#product")).toHaveAttribute("data-video-ready", "false");
    fireEvent.click(screen.getByRole("button", { name: "Retry the tour" }));
    expect(video).toHaveAttribute("src", cinematicStory.video);
    decode(video);
    tick();
    expect(video.currentTime).toBe(51);
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "cinematic");
    expect(screen.queryByRole("button", { name: "Retry the tour" })).toBeNull();
  });

  it("can enable motion again after the preference changes without reloading", () => {
    const { container } = render(<CinematicStory />);
    decode(container.querySelector("video")!);
    act(() => {
      query.matches = false;
      query.dispatchEvent(new Event("change"));
    });
    expect(container.querySelector("video")).toBeNull();
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "static");
    act(() => {
      query.matches = true;
      query.dispatchEvent(new Event("change"));
    });
    const video = container.querySelector("video")!;
    decode(video);
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "cinematic");
  });

  it("refreshes when a history-cached page becomes visible again", () => {
    const { container } = render(<CinematicStory />);
    decode(container.querySelector("video")!);
    mocks.refresh.mockClear();
    fireEvent(window, new Event("pageshow"));
    expect(mocks.refresh).toHaveBeenCalledOnce();
  });

  it("leaves no orphaned ticker or scroll trigger after StrictMode cleanup", () => {
    const { container, unmount } = render(
      <StrictMode>
        <CinematicStory />
      </StrictMode>,
    );
    decode(container.querySelector("video")!);
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "cinematic");
    unmount();
    expect(mocks.tickerAdd.mock.calls.length).toBeGreaterThan(0);
    expect(mocks.tickerRemove.mock.calls.map(([callback]) => callback)).toEqual(
      mocks.tickerAdd.mock.calls.map(([callback]) => callback),
    );
    expect(mocks.triggerKill).toHaveBeenCalledTimes(mocks.triggerCreate.mock.calls.length);
  });
});
