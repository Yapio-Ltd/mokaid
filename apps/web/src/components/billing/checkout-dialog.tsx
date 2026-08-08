import { useEffect } from "react";
import { ShieldCheck } from "lucide-react";
import { Dialog } from "@/components/ui/dialog";

export type CheckoutOutcome = "done" | "failed";

/**
 * On-site Tranzila checkout: loads the hosted payment page (PCI-DSS handled
 * by Tranzila) inside an iframe modal so the customer never leaves the app.
 *
 * After payment, Tranzila redirects the iframe to our /payment-result.html,
 * which postMessages `{ source: "mokaid-checkout", status }` back to this
 * window. Actual plan/credit activation is driven exclusively by the
 * server-side notify webhook — this dialog only reflects the outcome.
 */
export function TranzilaCheckoutDialog({
  saleUrl,
  title = "Secure checkout",
  onClose,
  onComplete,
}: {
  saleUrl: string | null;
  title?: string;
  onClose: () => void;
  onComplete: (outcome: CheckoutOutcome) => void;
}) {
  const open = saleUrl != null;

  useEffect(() => {
    if (!open) return;

    const onMessage = (event: MessageEvent) => {
      if (event.origin !== window.location.origin) return;
      const data = event.data as { source?: string; status?: string } | null;
      if (!data || data.source !== "mokaid-checkout") return;
      onComplete(data.status === "done" ? "done" : "failed");
    };

    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [open, onComplete]);

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next) onClose();
      }}
      title={title}
      className="w-[560px]"
    >
      <div className="space-y-3">
        {saleUrl && (
          <iframe
            src={saleUrl}
            title="Secure payment"
            allow="payment"
            className="h-[560px] w-full rounded-xl border border-border bg-white"
          />
        )}
        <p className="flex items-center justify-center gap-1.5 text-[11px] text-text-muted">
          <ShieldCheck size={13} className="shrink-0 text-success" />
          Payments are processed securely by Tranzila (PCI-DSS certified) — your card details
          never touch our servers.
        </p>
      </div>
    </Dialog>
  );
}
