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
  controllers: [] as Array<{
    request: ReturnType<typeof vi.fn>;
    tick: ReturnType<typeof vi.fn>;
    suspend: ReturnType<typeof vi.fn>;
    redraw: ReturnType<typeof vi.fn>;
    dispose: ReturnType<typeof vi.fn>;
    options: {
      onReady: () => void;
      onPresented: (time: number) => void;
      onError: () => void;
      onProgress?: (loaded: number, total: number) => void;
    };
  }>,
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
vi.mock("@/lib/cinematic-frame-controller", async () => {
  const actual = await vi.importActual<typeof import("@/lib/cinematic-frame-controller")>(
    "@/lib/cinematic-frame-controller",
  );
  return {
    ...actual,
    createCinematicFrameController: (options: (typeof mocks.controllers)[number]["options"]) => {
      const controller = {
        request: vi.fn(),
        tick: vi.fn(),
        suspend: vi.fn(),
        redraw: vi.fn(),
        dispose: vi.fn(),
        options,
      };
      mocks.controllers.push(controller);
      return controller;
    },
  };
});

let top = 2000;
let eligible = true;
let progress = 0;
let query: EventTarget & { matches: boolean; media: string };

beforeEach(() => {
  top = 2000;
  eligible = true;
  progress = 0;
  mocks.controllers.length = 0;
  query = Object.assign(new EventTarget(), {
    matches: true,
    media: "(prefers-reduced-motion: no-preference)",
  });
  vi.stubGlobal(
    "matchMedia",
    vi.fn((media: string) => {
      if (media.includes("orientation: portrait")) {
        return Object.assign(new EventTarget(), { matches: false, media });
      }
      query.matches = eligible;
      query.media = media;
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
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

function ready() {
  const controller = mocks.controllers.at(-1)!;
  act(() => {
    controller.options.onProgress?.(cinematicStory.frames.desktop.count, cinematicStory.frames.desktop.count);
    controller.options.onReady();
    controller.options.onPresented(storyTimeAtProgress(progress));
  });
}

function tick() {
  act(() => mocks.tickerAdd.mock.calls.at(-1)![0](1));
}

describe("cinematic story lifecycle", () => {
  it("keeps reduced-motion content readable and source-free", () => {
    eligible = false;
    const { container } = render(<CinematicStory />);
    expect(container.querySelector("canvas")).toBeNull();
    expect(screen.getAllByRole("img")).toHaveLength(3);
    expect(screen.getByRole("link", { name: /Build your team/ })).toHaveAttribute(
      "href",
      "/download",
    );
  });

  it("keeps prerendered content static, semantic and source-free", () => {
    vi.stubGlobal("__MOKAID_PRERENDER__", true);
    const { container } = render(<CinematicStory />);
    expect(container.querySelector("canvas")).toBeNull();
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "static");
  });

  it.each([390, 768, 1024, 1440])("loads the frame pack at viewport width %i", (width) => {
    vi.stubGlobal("innerWidth", width);
    const { container, unmount } = render(<CinematicStory />);
    expect(window.matchMedia).toHaveBeenCalledWith("(prefers-reduced-motion: no-preference)");
    expect(container.querySelector("canvas")).toBeTruthy();
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "loading");
    expect(mocks.tickerAdd).toHaveBeenCalledOnce();
    expect(screen.getByRole("link", { name: /Skip the tour/ })).toHaveAttribute("tabindex", "0");
    ready();
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "cinematic");
    expect(container.querySelector("#product")).toHaveAttribute("data-frames-ready", "true");
    unmount();
    expect(mocks.tickerRemove).toHaveBeenCalledOnce();
    expect(mocks.triggerKill).toHaveBeenCalledOnce();
    expect(mocks.controllers.at(-1)!.dispose).toHaveBeenCalled();
  });

  it("finishes loading after early entry and more than the old 12-second cutoff", () => {
    vi.useFakeTimers();
    const { container } = render(<CinematicStory />);
    top = 200;
    fireEvent.scroll(window);
    act(() => vi.advanceTimersByTime(20_000));
    expect(container.querySelector("canvas")).toBeTruthy();
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "loading");
    expect(screen.getByRole("button", { name: "Retry the tour" })).toBeVisible();
    ready();
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "cinematic");
  });

  it("can retry a stalled request", () => {
    vi.useFakeTimers();
    progress = 0.57;
    render(<CinematicStory />);
    const first = mocks.controllers.at(-1)!;
    act(() => vi.advanceTimersByTime(12_000));
    fireEvent.click(screen.getByRole("button", { name: "Retry the tour" }));
    expect(mocks.controllers.length).toBeGreaterThan(1);
    expect(first.dispose).toHaveBeenCalled();
    ready();
    tick();
    expect(mocks.controllers.at(-1)!.request).toHaveBeenCalled();
  });

  it("loads on a restored mid-story visit", () => {
    top = -200;
    progress = 0.57;
    const { container } = render(<CinematicStory />);
    ready();
    tick();
    expect(mocks.controllers.at(-1)!.request).toHaveBeenCalledWith(storyTimeAtProgress(progress));
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "cinematic");
  });

  it("reinitializes ownership after leaving and returning", () => {
    const first = render(<CinematicStory />);
    ready();
    first.unmount();
    top = -300;
    progress = 0.43;
    const second = render(<CinematicStory />);
    ready();
    tick();
    expect(mocks.controllers.at(-1)!.request).toHaveBeenCalledWith(32);
    expect(mocks.tickerAdd).toHaveBeenCalledTimes(2);
    second.unmount();
  });

  it("allows retrying a failed load at the current scroll position", () => {
    progress = 0.69;
    const { container } = render(<CinematicStory />);
    act(() => mocks.controllers.at(-1)!.options.onError());
    expect(container.querySelector("#product")).toHaveAttribute("data-frames-ready", "false");
    fireEvent.click(screen.getByRole("button", { name: "Retry the tour" }));
    ready();
    tick();
    expect(mocks.controllers.at(-1)!.request).toHaveBeenCalledWith(51);
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "cinematic");
  });

  it("can enable motion again after the preference changes without reloading", () => {
    const { container } = render(<CinematicStory />);
    ready();
    act(() => {
      query.matches = false;
      query.dispatchEvent(new Event("change"));
    });
    expect(container.querySelector("canvas")).toBeNull();
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "static");
    act(() => {
      query.matches = true;
      query.dispatchEvent(new Event("change"));
    });
    ready();
    expect(container.querySelector("#product")).toHaveAttribute("data-mode", "cinematic");
  });

  it("refreshes when a history-cached page becomes visible again", () => {
    render(<CinematicStory />);
    ready();
    mocks.refresh.mockClear();
    fireEvent(window, new Event("pageshow"));
    expect(mocks.refresh).toHaveBeenCalledOnce();
  });

  it("leaves no orphaned ticker or scroll trigger after StrictMode cleanup", () => {
    const { unmount } = render(
      <StrictMode>
        <CinematicStory />
      </StrictMode>,
    );
    ready();
    unmount();
    expect(mocks.tickerRemove.mock.calls.map(([callback]) => callback)).toEqual(
      mocks.tickerAdd.mock.calls.map(([callback]) => callback),
    );
    expect(mocks.triggerKill).toHaveBeenCalledTimes(mocks.triggerCreate.mock.calls.length);
  });

  it("exposes fingerprinted frame packs in the story manifest", () => {
    expect(cinematicStory.frames.desktop.count).toBe(1776);
    expect(cinematicStory.frames.mobile.count).toBe(888);
    expect(cinematicStory.frames.desktop.pattern).toContain("cinematic-frames.");
    expect(cinematicStory.frames.desktop.firstIndex).toBe(1);
  });
});
