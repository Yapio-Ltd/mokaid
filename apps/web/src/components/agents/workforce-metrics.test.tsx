import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import type { Task } from "@/api/types";
import {
  getTaskCompletionBuckets,
  PerformanceScoreGauge,
  TaskActivitySparkline,
  TaskCompletionBars,
  TaskProgressBars,
} from "./workforce-metrics";

const now = new Date("2026-09-16T12:00:00Z");
const completed = (completed_at: string | null, overrides: Partial<Task> = {}) => ({
  assigned_agent_id: "orion",
  status: "completed" as const,
  completed_at,
  ...overrides,
});

afterEach(cleanup);

describe("task completion history", () => {
  it("buckets persisted completion timestamps by UTC day within the requested window", () => {
    const result = getTaskCompletionBuckets(
      [
        completed("2026-09-14T00:00:00Z"),
        completed("2026-09-15T23:30:00-04:00"),
        completed("2026-09-16T12:00:00Z"),
        completed("2026-09-13T23:59:59Z"),
        completed("2026-09-16T12:00:01Z"),
        completed("2026-09-17T01:00:00Z"),
      ],
      { days: 3, now },
    );
    expect(result).toEqual([
      { date: "2026-09-14", count: 1 },
      { date: "2026-09-15", count: 0 },
      { date: "2026-09-16", count: 2 },
    ]);
  });

  it("never substitutes task updates, another agent's activity, or unfinished tasks", () => {
    expect(
      getTaskCompletionBuckets(
        [
          completed(null, { updated_at: now.toISOString() }),
          completed("invalid"),
          completed(now.toISOString(), { assigned_agent_id: "mira" }),
          completed(now.toISOString(), { status: "in_review" }),
          completed(now.toISOString(), { status: "canceled" }),
        ],
        { agentId: "orion", days: 1, now },
      ),
    ).toEqual([{ date: "2026-09-16", count: 0 }]);
  });

  it("distinguishes no completions from data that has not loaded", () => {
    const { rerender } = render(<TaskActivitySparkline tasks={undefined} now={now} />);
    expect(
      screen.getByRole("img", { name: "Task completion history unavailable" }),
    ).toBeInTheDocument();
    rerender(<TaskActivitySparkline tasks={[]} now={now} />);
    const empty = screen.getByRole("img", { name: /no dated completions in loaded task records/ });
    expect(empty.querySelector("polyline")).toBeNull();
    expect(empty).toHaveAttribute("data-empty", "true");
  });

  it("gives days with no completions zero bar height", () => {
    render(<TaskCompletionBars tasks={[completed(now.toISOString())]} days={3} now={now} />);
    const chart = screen.getByRole("img", { name: /1 completed task in loaded task records/ });
    expect(
      [...chart.querySelectorAll("rect")].map((bar) => Number(bar.getAttribute("height"))),
    ).toEqual([0, 0, 28]);
  });
});

describe("current task and score graphics", () => {
  it("plots actual progress for active tasks and excludes closed tasks", () => {
    const tasks = [
      {
        id: "first",
        title: "Research",
        assigned_agent_id: "orion",
        status: "in_progress" as const,
        progress_percent: 25,
      },
      {
        id: "second",
        title: "Review",
        assigned_agent_id: "orion",
        status: "in_review" as const,
        progress_percent: 80,
      },
      {
        id: "third",
        title: "Done",
        assigned_agent_id: "orion",
        status: "completed" as const,
        progress_percent: 100,
      },
    ];
    render(<TaskProgressBars tasks={tasks} height={102} />);
    const chart = screen.getByRole("img", { name: /2 of 2 active tasks/ });
    expect(
      [...chart.querySelectorAll('rect[opacity="0.85"]')].map((bar) =>
        Number(bar.getAttribute("height")),
      ),
    ).toEqual([25, 80]);
    expect(chart).toHaveTextContent("Research: 25% complete");
    expect(chart).not.toHaveTextContent("Done");
  });

  it("identifies performance as a static score and keeps zero distinct from unknown", () => {
    const { rerender } = render(<PerformanceScoreGauge score={0} />);
    const score = screen.getByRole("img", { name: /Current performance score: 0 out of 100/ });
    expect(score).toHaveAccessibleName(/not a success rate or historical trend/);
    expect(score.querySelectorAll('rect[opacity="0.85"]')).toHaveLength(0);
    rerender(<PerformanceScoreGauge score={null} />);
    expect(screen.getByRole("img", { name: "Performance score unavailable" })).toBeInTheDocument();
  });
});
