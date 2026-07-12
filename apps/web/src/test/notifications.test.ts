import { describe, expect, it } from "vitest";
import {
  formatNotificationBody,
  formatNotificationTitle,
  humanizeErrorMessage,
  notificationCta,
  notificationTone,
} from "@/lib/notifications";
import type { AppNotification } from "@/api/types";

const base: AppNotification = {
  id: "1",
  kind: "ai_run_failed",
  title: "Task failed: change the design to be retro",
  body: null,
  resource_type: "task",
  resource_id: "t1",
  read_at: null,
  inserted_at: new Date().toISOString(),
};

describe("humanizeErrorMessage", () => {
  it("turns OpenAI credit dumps into a top-up message", () => {
    const raw =
      "Error code: 400 - {'type': 'error', 'error': {'type': 'invalid_request_error', 'message': 'Your credit balance is too low to run this request. Please purchase credits.'}}";
    const msg = humanizeErrorMessage(raw);
    expect(msg).toMatch(/credit balance is too low/i);
    expect(msg).not.toMatch(/Error code/);
    expect(msg).not.toMatch(/invalid_request_error/);
  });

  it("maps rate limits", () => {
    expect(humanizeErrorMessage("Error code: 429 - rate_limit_exceeded")).toMatch(/overloaded/i);
  });
});

describe("formatNotificationTitle", () => {
  it("splits status eyebrow from task title", () => {
    const { eyebrow, headline } = formatNotificationTitle(base);
    expect(eyebrow).toBe("Couldn't finish");
    expect(headline).toBe("change the design to be retro");
  });
});

describe("formatNotificationBody", () => {
  it("humanizes legacy raw failure bodies", () => {
    const body = formatNotificationBody({
      ...base,
      body: "Error code: 400 - {'type': 'error', 'error': {'message': 'Your credit balance is too low'}}",
    });
    expect(body).toMatch(/credit balance is too low/i);
  });
});

describe("notification helpers", () => {
  it("picks tone and CTA by kind", () => {
    expect(notificationTone("ai_run_completed")).toBe("warning");
    expect(notificationTone("ai_run_failed")).toBe("error");
    expect(notificationCta(base)).toBe("Voir conversation");
    expect(
      notificationCta({ ...base, kind: "ai_run_completed", title: "Ready for review: X" }),
    ).toBe("Approve");
  });
});
