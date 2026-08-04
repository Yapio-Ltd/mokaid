import { Link } from "@tanstack/react-router";
import { Building2 } from "lucide-react";
import {
  EntityContactCard,
  LegalDocLayout,
  Prose,
  SectionTitle,
} from "@/components/legal/legal-doc-layout";
import {
  GOVERNING_LAW,
  HOSTING_DETAILS,
  HOSTING_PROVIDER,
  LEGAL_ENTITY_NAME,
  PRODUCT_NAME,
  SITE_DOMAIN,
  SITE_URL,
} from "@/lib/legal-config";

export function LegalPage() {
  return (
    <LegalDocLayout
      icon={Building2}
      title="Legal Notice"
      excludeFooterLink="/legal"
      intro={
        <p className="mt-3 text-sm leading-relaxed text-text-secondary">
          This legal notice identifies the publisher of{" "}
          <strong className="text-text">{SITE_DOMAIN}</strong> and the {PRODUCT_NAME} online
          service, operated by {LEGAL_ENTITY_NAME}.
        </p>
      }
    >
      <section>
        <SectionTitle index="1" title="Publisher / operator" />
        <EntityContactCard />
        <Prose className="mt-4">
          Website:{" "}
          <a
            href={SITE_URL}
            className="text-primary-light hover:underline"
            target="_blank"
            rel="noopener noreferrer"
          >
            {SITE_DOMAIN}
          </a>
          . Product brand: {PRODUCT_NAME}.
        </Prose>
      </section>

      <section>
        <SectionTitle index="2" title="Hosting" />
        <Prose>
          The website and related application services are hosted primarily by{" "}
          <strong className="text-text">{HOSTING_PROVIDER}</strong>. {HOSTING_DETAILS}
        </Prose>
      </section>

      <section>
        <SectionTitle index="3" title="Intellectual property" />
        <Prose>
          All content on the {PRODUCT_NAME} platform (text, graphics, logos, interfaces, software,
          databases, trademarks) is protected by intellectual property law and owned by{" "}
          {LEGAL_ENTITY_NAME} or its licensors. Unauthorized reproduction, modification, or
          commercial exploitation is prohibited without prior written consent.
        </Prose>
      </section>

      <section>
        <SectionTitle index="4" title="Liability" />
        <Prose>
          {LEGAL_ENTITY_NAME} strives to keep public information accurate, but does not guarantee
          completeness or absence of errors. Use of information and services is at your own risk,
          subject to the{" "}
          <Link to="/terms" className="text-primary-light hover:underline">
            Terms of Service
          </Link>
          .
        </Prose>
      </section>

      <section>
        <SectionTitle index="5" title="Personal data, cookies, and consumer documents" />
        <Prose>
          Personal data processing is described in our{" "}
          <Link to="/privacy" className="text-primary-light hover:underline">
            Privacy Policy
          </Link>
          . Cookies are described in our{" "}
          <Link to="/cookies" className="text-primary-light hover:underline">
            Cookie Policy
          </Link>
          . Use of the service is governed by the{" "}
          <Link to="/terms" className="text-primary-light hover:underline">
            Terms of Service
          </Link>
          . Cancellations and refunds are governed by the{" "}
          <Link to="/refund" className="text-primary-light hover:underline">
            Refund & Cancellation Policy
          </Link>
          .
        </Prose>
      </section>

      <section>
        <SectionTitle index="6" title="Applicable law" />
        <Prose>
          Subject to mandatory consumer protections, the website and services are governed by{" "}
          {GOVERNING_LAW}, as further detailed in the Terms of Service.
        </Prose>
      </section>

      <section>
        <SectionTitle index="7" title="Contact" />
        <Prose>For questions about this legal notice:</Prose>
        <EntityContactCard />
      </section>
    </LegalDocLayout>
  );
}
