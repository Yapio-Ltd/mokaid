import { Link } from "@tanstack/react-router";
import { RotateCcw } from "lucide-react";
import {
  EntityContactCard,
  LegalDocLayout,
  Prose,
  SectionTitle,
  SubList,
} from "@/components/legal/legal-doc-layout";
import {
  CONTACT_EMAIL,
  LEGAL_ENTITY_NAME,
  PAYMENT_PROVIDER,
  PRODUCT_NAME,
} from "@/lib/legal-config";

export function RefundPage() {
  return (
    <LegalDocLayout
      icon={RotateCcw}
      title="Refund & Cancellation Policy"
      excludeFooterLink="/refund"
      intro={
        <>
          <p className="mt-3 text-sm leading-relaxed text-text-secondary">
            This Refund & Cancellation Policy explains how you can cancel {PRODUCT_NAME}{" "}
            subscriptions and when refunds may be available. It forms part of the{" "}
            <Link to="/terms" className="text-primary-light hover:underline">
              Terms of Service
            </Link>{" "}
            between you and {LEGAL_ENTITY_NAME}. Payments are processed by {PAYMENT_PROVIDER}.
          </p>
          <p className="mt-3 text-sm leading-relaxed text-text-secondary">
            Where Israeli Consumer Protection Law 5741-1981 or other mandatory consumer law
            grants you stronger rights, those rights prevail over this Policy.
          </p>
        </>
      }
    >
      <section>
        <SectionTitle index="1" title="Subscriptions overview" />
        <Prose>
          {PRODUCT_NAME} may offer free and paid plans (for example Free, Starter, and
          Professional tiers) billed monthly or annually, and optional one-time or prepaid AI
          credit packs for usage beyond included quotas. Plan names and prices are shown at
          purchase and in workspace billing settings.
        </Prose>
      </section>

      <section>
        <SectionTitle index="2" title="How to cancel a subscription" />
        <Prose>You may cancel a paid subscription at any time by:</Prose>
        <SubList
          items={[
            "Using the cancellation or plan-management controls in workspace Billing settings (when available); or",
            `Emailing ${CONTACT_EMAIL} from the email address on your account with a clear cancellation request.`,
          ]}
        />
        <Prose className="mt-4">
          <strong className="text-text">Effect of cancellation.</strong> Unless mandatory law or a
          written offer states otherwise, cancellation takes effect at the end of the current paid
          billing period. You retain access to paid features until that date. We do not
          automatically issue pro-rata refunds for unused days of a period already paid, except as
          set out below or required by law.
        </Prose>
        <Prose className="mt-3">
          Auto-renewal will stop after cancellation is confirmed for the upcoming period. You
          remain responsible for charges incurred before cancellation takes effect.
        </Prose>
      </section>

      <section>
        <SectionTitle index="3" title="Consumer cooling-off (Israel and similar laws)" />
        <Prose>
          If you are a <strong className="text-text">consumer</strong> under Israeli law
          purchasing the service remotely (including online), you may have a statutory right to
          cancel certain transactions within{" "}
          <strong className="text-text">fourteen (14) days</strong> of the transaction or of
          receiving required consumer information, whichever is later under the Consumer Protection
          Law and related regulations, subject to statutory conditions and exceptions.
        </Prose>
        <Prose className="mt-3">
          <strong className="text-text">Digital service exception.</strong> For digital content or
          ongoing digital services that begin immediately with your explicit request and your
          acknowledgment that you lose the cancellation right once performance has begun, the
          cooling-off right may not apply to the extent permitted by law. Where we rely on this
          exception, we will make that clear at checkout when technically feasible.
        </Prose>
        <Prose className="mt-3">
          To exercise a statutory cooling-off right (when available), contact us at{" "}
          <a href={`mailto:${CONTACT_EMAIL}`} className="text-primary-light hover:underline">
            {CONTACT_EMAIL}
          </a>{" "}
          with your account email, the purchase or invoice reference, and a clear statement that
          you cancel under your consumer cancellation right. Eligible refunds will be processed via
          the original payment method through {PAYMENT_PROVIDER} within a reasonable time after
          approval.
        </Prose>
      </section>

      <section>
        <SectionTitle index="4" title="Business (B2B) purchases" />
        <Prose>
          If you purchase {PRODUCT_NAME} primarily for business, trade, or professional purposes
          (not as a consumer), paid subscription fees and credit-pack prices are generally{" "}
          <strong className="text-text">non-refundable</strong>, including for partial periods,
          except where:
        </Prose>
        <SubList
          items={[
            "Mandatory law requires a refund;",
            "We confirm a refund in writing for a specific case;",
            "We terminate the service for convenience or permanently discontinue a paid plan you prepaid, in which case we will provide a pro-rata credit or refund of unused prepaid fees; or",
            "A material, prolonged service outage solely attributable to us makes the service substantially unusable for a continuous period we determine in good faith warrants a remedy (service credit or partial refund at our discretion).",
          ]}
        />
      </section>

      <section>
        <SectionTitle index="5" title="AI credit packs" />
        <Prose>For prepaid AI credit or usage packs:</Prose>
        <SubList
          items={[
            {
              label: "Consumed credits",
              detail: "Credits already used are non-refundable.",
            },
            {
              label: "Unused credits",
              detail:
                "Unused prepaid credits are generally non-refundable after purchase, except under Section 3 (consumer cooling-off, if applicable) or a written exception from us.",
            },
            {
              label: "Expiry",
              detail:
                "Credits may expire as disclosed at purchase or in product documentation. Expired unused credits are not refundable.",
            },
          ]}
        />
      </section>

      <section>
        <SectionTitle index="6" title="Chargebacks and payment disputes" />
        <Prose>
          Before initiating a chargeback with your bank or card issuer, please contact us so we can
          investigate and, if appropriate, issue a refund. Unwarranted chargebacks may lead to
          account suspension pending resolution. Fraudulent chargebacks may be pursued as permitted
          by law.
        </Prose>
      </section>

      <section>
        <SectionTitle index="7" title="Termination for cause" />
        <Prose>
          If we suspend or terminate your account for breach of the Terms of Service (including
          non-payment fraud, abuse, or illegal use), you are not entitled to a refund of amounts
          already paid, except to the extent mandatory law requires otherwise.
        </Prose>
      </section>

      <section>
        <SectionTitle index="8" title="How to request a refund" />
        <Prose>Email us at:</Prose>
        <EntityContactCard attention="Billing / refunds" />
        <Prose className="mt-4">Include:</Prose>
        <SubList
          items={[
            "Account email and workspace name (if any).",
            "Date and amount of the charge, and invoice or transaction ID if available.",
            "Reason for the request (cancellation, consumer right, billing error, etc.).",
          ]}
        />
        <Prose className="mt-4">
          We aim to acknowledge requests within five (5) business days and complete approved
          refunds via {PAYMENT_PROVIDER} within fourteen (14) business days after approval, subject
          to bank and provider timelines. Currency and method follow the original payment path
          where possible.
        </Prose>
      </section>

      <section>
        <SectionTitle index="9" title="Service discontinuation" />
        <Prose>
          If {LEGAL_ENTITY_NAME} permanently discontinues {PRODUCT_NAME} or a prepaid paid plan,
          we will provide reasonable advance notice when practicable, allow data export where
          available, and refund or credit unused prepaid fees on a pro-rata basis for periods after
          the discontinuation date, unless mandatory law requires a different remedy.
        </Prose>
      </section>

      <section>
        <SectionTitle index="10" title="Contact and related documents" />
        <Prose>
          Questions about this Policy:{" "}
          <a href={`mailto:${CONTACT_EMAIL}`} className="text-primary-light hover:underline">
            {CONTACT_EMAIL}
          </a>
          . Also see our{" "}
          <Link to="/terms" className="text-primary-light hover:underline">
            Terms of Service
          </Link>{" "}
          and{" "}
          <Link to="/privacy" className="text-primary-light hover:underline">
            Privacy Policy
          </Link>
          .
        </Prose>
      </section>
    </LegalDocLayout>
  );
}
