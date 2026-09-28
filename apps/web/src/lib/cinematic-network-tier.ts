/** Desktop network tier for cinematic frame densification. Mobile never upgrades. */

export type DesktopTier = "base" | "high";

export interface NetworkConnectionLike {
  saveData?: boolean;
  effectiveType?: string;
  downlink?: number;
  rtt?: number;
  addEventListener?: (type: string, listener: () => void) => void;
}

export interface TierResolveInput {
  connection?: NetworkConnectionLike | null;
  online?: boolean;
  /** When Network Information API is missing (Safari), allow delayed high upgrade. */
  allowMissingApiUpgrade?: boolean;
}

/**
 * Resolve the maximum desktop densify tier. Always bootstrap with base for TTI;
 * callers enable high fetch only when this returns "high".
 */
export function resolveDesktopTier(input: TierResolveInput = {}): DesktopTier {
  const online = input.online ?? (typeof navigator !== "undefined" ? navigator.onLine : true);
  if (!online) return "base";

  const connection = input.connection ?? readNavigatorConnection();
  if (!connection) {
    // Safari / Firefox: no NetInfo — upgrade on online desktop after idle gate in UI.
    return input.allowMissingApiUpgrade === false ? "base" : "high";
  }

  if (connection.saveData) return "base";

  const effective = (connection.effectiveType || "").toLowerCase();
  if (effective === "slow-2g" || effective === "2g") return "base";

  const downlink = Number(connection.downlink);
  if (Number.isFinite(downlink) && downlink > 0 && downlink < 1.5) return "base";

  if (effective === "3g") {
    const rtt = Number(connection.rtt);
    if (Number.isFinite(downlink) && downlink >= 1.5 && (!Number.isFinite(rtt) || rtt <= 300)) {
      return "base"; // stay base on 3g; high only on strong 4g+
    }
    return "base";
  }

  // 4g / unknown with healthy downlink, or missing effectiveType with good downlink.
  if (Number.isFinite(downlink) && downlink >= 5) return "high";
  if (effective === "4g") return "high";
  // Desktop fibre often reports 4g or empty effectiveType with high downlink.
  if (!effective && (!Number.isFinite(downlink) || downlink >= 5)) return "high";
  // Conservative default when signals are ambiguous but not explicitly slow.
  if (!effective && !Number.isFinite(downlink)) return "high";
  return "base";
}

export function readNavigatorConnection(): NetworkConnectionLike | null {
  if (typeof navigator === "undefined") return null;
  const nav = navigator as Navigator & { connection?: NetworkConnectionLike; mozConnection?: NetworkConnectionLike; webkitConnection?: NetworkConnectionLike };
  return nav.connection || nav.mozConnection || nav.webkitConnection || null;
}
