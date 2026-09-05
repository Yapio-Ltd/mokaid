/** Single source of truth for public legal identity and document metadata. */

export const LEGAL_ENTITY_NAME = "Yapio";
export const PRODUCT_NAME = "Mokaid";
export const PRODUCT_DISPLAY = "mokaid";
export const SITE_DOMAIN = "mokaid.io";
export const SITE_URL = `https://${SITE_DOMAIN}`;

export const CONTACT_EMAIL = "contact@yapio.io";
export const PRIVACY_EMAIL = "contact@yapio.io";

/** Registered office / principal place of business */
export const LEGAL_ADDRESS_LINES = [
  "Chicago 136",
  "Haifa",
  "Israel",
] as const;

export const LEGAL_ADDRESS_SINGLE = "Chicago 136, Haifa, Israel";

/** Company registration number (ח.פ.) — set when available */
export const COMPANY_REGISTRATION_NUMBER = "" as string;

export const PAYMENT_PROVIDER = "Stripe";
export const HOSTING_PROVIDER = "Render";
export const HOSTING_DETAILS =
  "Render Services, Inc. — cloud infrastructure. Contact us for full hosting particulars.";

export const GOVERNING_LAW = "the laws of the State of Israel";
export const JURISDICTION_COURTS = "the competent courts of Haifa, Israel";

/** Display date on all legal documents */
export const EFFECTIVE_DATE = "August 4, 2026";

export const COOKIE_CONSENT_KEY = "mokaid_cookie_consent";

export type CookieConsentValue = "accepted" | "rejected";

export function getCookieConsent(): CookieConsentValue | null {
  if (typeof window === "undefined") return null;
  try {
    const v = localStorage.getItem(COOKIE_CONSENT_KEY);
    if (v === "accepted" || v === "rejected") return v;
  } catch {
    /* private mode */
  }
  return null;
}

export function setCookieConsent(value: CookieConsentValue): void {
  try {
    localStorage.setItem(COOKIE_CONSENT_KEY, value);
  } catch {
    /* private mode */
  }
}

export function formatEntityBlock(): string[] {
  const lines = [
    LEGAL_ENTITY_NAME,
    ...LEGAL_ADDRESS_LINES,
  ];
  if (COMPANY_REGISTRATION_NUMBER) {
    lines.push(`Registration no.: ${COMPANY_REGISTRATION_NUMBER}`);
  }
  return lines;
}
