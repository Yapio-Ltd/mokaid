import { useEffect, useState } from "react";
import { Link } from "@tanstack/react-router";
import { Cookie } from "lucide-react";
import {
  getCookieConsent,
  setCookieConsent,
  type CookieConsentValue,
} from "@/lib/legal-config";
import { Button } from "@/components/ui/button";

export function CookieConsent() {
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    setVisible(getCookieConsent() === null);
  }, []);

  const choose = (value: CookieConsentValue) => {
    setCookieConsent(value);
    setVisible(false);
    window.dispatchEvent(
      new window.CustomEvent("mokaid:cookie-consent", { detail: value }),
    );
  };

  if (!visible) return null;

  return (
    <div
      role="dialog"
      aria-label="Cookie preferences"
      className="fixed inset-x-0 bottom-0 z-[100] p-4 sm:bottom-4 sm:left-4 sm:right-auto sm:max-w-md sm:p-0"
    >
      <div className="rounded-xl border border-border bg-surface/95 p-4 shadow-lg backdrop-blur-md">
        <div className="mb-2 flex items-center gap-2 text-sm font-semibold text-text">
          <Cookie size={16} className="text-primary-light" />
          Cookies
        </div>
        <p className="text-xs leading-relaxed text-text-secondary">
          We use essential cookies to run the service. Optional analytics cookies are used only
          with your consent. See our{" "}
          <Link to="/cookies" className="text-primary-light hover:underline">
            Cookie Policy
          </Link>{" "}
          and{" "}
          <Link to="/privacy" className="text-primary-light hover:underline">
            Privacy Policy
          </Link>
          .
        </p>
        <div className="mt-3 flex flex-wrap gap-2">
          <Button size="sm" onClick={() => choose("accepted")}>
            Accept all
          </Button>
          <Button size="sm" variant="secondary" onClick={() => choose("rejected")}>
            Essential only
          </Button>
        </div>
      </div>
    </div>
  );
}

/** Call after consent is set; returns whether non-essential analytics may load. */
export function mayLoadAnalytics(): boolean {
  return getCookieConsent() === "accepted";
}
