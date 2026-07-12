import type { AppNotification } from "@/api/types";

/** Strip technical provider dumps into short, actionable copy for humans. */
export function humanizeErrorMessage(raw: string | null | undefined): string {
  if (!raw?.trim()) {
    return "Something went wrong while working on this task. Open it to retry.";
  }

  const trimmed = raw.trim();
  if (alreadyFriendly(trimmed)) return trimmed;

  const lower = trimmed.toLowerCase();
  const extracted = extractProviderMessage(trimmed);
  const extractedLower = extracted?.toLowerCase() ?? "";

  if (matchesCredit(lower) || matchesCredit(extractedLower)) {
    return "We couldn't complete this task because your AI credit balance is too low. Top up credits, then try again.";
  }
  if (matchesRateLimit(lower) || matchesRateLimit(extractedLower)) {
    return "The AI service is temporarily overloaded. Wait a moment, then try again.";
  }
  if (matchesAuth(lower) || matchesAuth(extractedLower)) {
    return "The AI service rejected the request (authentication). Check your API or billing settings, then try again.";
  }
  if (matchesTimeout(lower) || matchesTimeout(extractedLower)) {
    return "The agent ran out of time before finishing. Open the task and try again.";
  }
  if (matchesNetwork(lower) || matchesNetwork(extractedLower)) {
    return "We couldn't reach the AI service. Check your connection and try again.";
  }
  if (matchesContext(lower) || matchesContext(extractedLower)) {
    return "This task was too large for the AI to process in one go. Try splitting it into smaller steps.";
  }
  if (matchesPolicy(lower) || matchesPolicy(extractedLower)) {
    return "The AI couldn't complete this task because of a content policy restriction. Try rephrasing the request.";
  }
  if (extracted && !looksTechnical(extracted)) {
    return capitalizeSentence(extracted);
  }
  if (looksTechnical(trimmed)) {
    return "Something went wrong while the agent was working. Open the task to see details and retry.";
  }
  return capitalizeSentence(trimmed);
}

export type NotificationTone = "success" | "error" | "warning" | "info";

export function notificationTone(kind: string, resourceStatus?: string | null): NotificationTone {
  if (resourceStatus === "completed") return "success";
  if (resourceStatus === "canceled") return "info";
  if (kind === "ai_run_completed") return "warning";
  if (kind === "ai_run_failed" || kind.includes("failed") || kind.includes("rejected")) {
    return "error";
  }
  if (kind === "approval_requested" || kind.includes("approval")) return "warning";
  return "info";
}

export function formatNotificationTitle(n: AppNotification): {
  eyebrow: string;
  headline: string;
} {
  const title = n.title ?? "";
  const colon = title.indexOf(": ");
  const headline =
    colon > 0 && colon < 40 ? title.slice(colon + 2).trim() || title : title || "Notification";

  if (n.resource_status === "completed" && actionKind(n.kind)) {
    return { eyebrow: "Approved", headline };
  }
  if (n.resource_status === "canceled" && actionKind(n.kind)) {
    return { eyebrow: "Canceled", headline };
  }
  if (n.resource_status === "in_progress" && n.kind === "ai_run_completed") {
    return { eyebrow: "Revisions requested", headline };
  }

  if (colon > 0 && colon < 40) {
    return {
      eyebrow: polishEyebrow(title.slice(0, colon), n.kind),
      headline,
    };
  }

  return {
    eyebrow: polishEyebrow(defaultEyebrow(n.kind), n.kind),
    headline,
  };
}

export function formatNotificationBody(n: AppNotification): string | null {
  if (n.resource_status === "completed" && actionKind(n.kind)) {
    return "This task was approved.";
  }
  if (n.resource_status === "in_progress" && n.kind === "ai_run_completed") {
    return "Sent back for revisions.";
  }

  if (!n.body?.trim()) return null;

  // Failed AI runs historically stored raw SDK errors — always humanize those.
  if (n.kind === "ai_run_failed" || looksTechnical(n.body)) {
    // Prefer keeping a leading agent sentence if an older backend version added one.
    const match = n.body.match(/^(.+? ran into a problem\.)\s*([\s\S]*)$/i);
    if (match) {
      return humanizeErrorMessage(match[2] || match[1]);
    }
    return humanizeErrorMessage(n.body);
  }

  // Older completed copy said "The agent finished…" — shorten now that the avatar shows who.
  if (n.kind === "ai_run_completed" && n.body.includes("The agent finished")) {
    return "Finished this task. Review the output and approve or request changes.";
  }

  return n.body.trim();
}

export function notificationCta(n: AppNotification): string | null {
  if (n.resource_type !== "task") return null;
  if (n.resource_status === "completed") return "View task";
  if (n.resource_status === "canceled") return "View task";
  if (n.kind === "ai_run_failed") return "Voir conversation";
  if (n.kind === "approval_requested") return "Approve";
  if (n.kind === "ai_run_completed") return "Approve";
  return "Open";
}

/** True when this notification originally asked for a review/approval decision. */
export function notificationNeedsAction(n: AppNotification): boolean {
  if (n.resource_type !== "task") return false;
  if (!actionKind(n.kind)) return false;
  if (n.resource_status === "completed" || n.resource_status === "canceled") return false;
  if (n.kind === "ai_run_completed" && n.resource_status === "in_progress") return false;
  return true;
}

function actionKind(kind: string): boolean {
  return kind === "ai_run_completed" || kind === "approval_requested";
}

function polishEyebrow(label: string, kind: string): string {
  const map: Record<string, string> = {
    "Task failed": "Couldn't finish",
    "Couldn't finish": "Couldn't finish",
    "Ready for review": "Ready for review",
    "Approval needed": "Needs approval",
    "New task assigned": "New task",
  };
  if (map[label]) return map[label];
  if (kind === "ai_run_failed") return "Couldn't finish";
  return label;
}

function defaultEyebrow(kind: string): string {
  switch (kind) {
    case "ai_run_completed":
      return "Ready for review";
    case "ai_run_failed":
      return "Couldn't finish";
    case "approval_requested":
      return "Needs approval";
    case "task_assigned":
      return "New task";
    default:
      return "Update";
  }
}

function alreadyFriendly(message: string): boolean {
  return (
    message.startsWith("We couldn't") ||
    message.startsWith("The agent") ||
    message.startsWith("The AI") ||
    message.startsWith("Something went wrong") ||
    message.startsWith("Sorry") ||
    message.startsWith("Je ") ||
    message.startsWith("Voilà")
  );
}

function matchesCredit(text: string) {
  return (
    text.includes("credit balance") ||
    text.includes("insufficient credit") ||
    text.includes("insufficient_credits") ||
    text.includes("out of credits") ||
    text.includes("billing soft limit") ||
    text.includes("exceeded your current quota") ||
    text.includes("payment required") ||
    text.includes("purchase credits")
  );
}

function matchesRateLimit(text: string) {
  return (
    text.includes("rate limit") ||
    text.includes("rate_limit") ||
    text.includes("too many requests") ||
    text.includes("error code: 429")
  );
}

function matchesAuth(text: string) {
  return (
    text.includes("invalid api key") ||
    text.includes("incorrect api key") ||
    text.includes("authentication") ||
    text.includes("unauthorized") ||
    text.includes("error code: 401") ||
    text.includes("error code: 403")
  );
}

function matchesTimeout(text: string) {
  return text.includes("timeout") || text.includes("timed out") || text.includes("deadline exceeded");
}

function matchesNetwork(text: string) {
  return (
    text.includes("connection") ||
    text.includes("network") ||
    text.includes("unreachable") ||
    text.includes("dns")
  );
}

function matchesContext(text: string) {
  return (
    text.includes("context length") ||
    text.includes("maximum context") ||
    text.includes("token limit") ||
    text.includes("too many tokens")
  );
}

function matchesPolicy(text: string) {
  return (
    text.includes("content policy") ||
    text.includes("content_filter") ||
    text.includes("safety system") ||
    text.includes("refused to")
  );
}

function looksTechnical(message: string): boolean {
  return (
    message.includes("Error code:") ||
    message.includes("{'type'") ||
    message.includes('"type":') ||
    message.includes("invalid_request_error") ||
    message.includes("Traceback") ||
    message.includes("Exception") ||
    /\b(APIStatusError|HTTPError|StatusCodeError)\b/.test(message)
  );
}

function extractProviderMessage(raw: string): string | null {
  const patterns = [
    /['"]message['"]\s*:\s*['"]([^'"]+)['"]/i,
    /message['"]?\s*[:=]\s*['"]([^'"]+)['"]/i,
  ];
  for (const pattern of patterns) {
    const match = raw.match(pattern);
    if (match?.[1]?.trim()) return match[1].trim();
  }
  return null;
}

function capitalizeSentence(text: string): string {
  let value = text.trim();
  if (value.length > 180) value = `${value.slice(0, 177)}…`;
  if (!value) return value;
  return value.charAt(0).toUpperCase() + value.slice(1);
}
