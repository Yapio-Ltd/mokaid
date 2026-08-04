import { Link } from "@tanstack/react-router";
import { Cookie } from "lucide-react";
import {
  EntityContactCard,
  LegalDocLayout,
  Prose,
  SectionTitle,
  SubList,
} from "@/components/legal/legal-doc-layout";
import {
  COOKIE_CONSENT_KEY,
  LEGAL_ENTITY_NAME,
  PAYMENT_PROVIDER,
  PRODUCT_NAME,
  SITE_DOMAIN,
} from "@/lib/legal-config";

export function CookiesPage() {
  return (
    <LegalDocLayout
      icon={Cookie}
      title="Cookie Policy"
      excludeFooterLink="/cookies"
      intro={
        <p className="mt-3 text-sm leading-relaxed text-text-secondary">
          This Cookie Policy explains how {LEGAL_ENTITY_NAME} uses cookies and similar technologies
          when you visit or use the {PRODUCT_NAME} platform at{" "}
          <strong className="text-text">{SITE_DOMAIN}</strong>. It should be read with our{" "}
          <Link to="/privacy" className="text-primary-light hover:underline">
            Privacy Policy
          </Link>
          .
        </p>
      }
    >
      <section>
        <SectionTitle index="1" title="What is a cookie?" />
        <Prose>
          A cookie is a small text file placed on your device when you browse a website. Similar
          technologies include local storage, session storage, and pixels. They help operate the
          site, remember preferences, and—if you consent—understand aggregate usage.
        </Prose>
      </section>

      <section>
        <SectionTitle index="2" title="Cookies we use" />
        <Prose>{PRODUCT_NAME} uses the following categories:</Prose>
        <SubList
          items={[
            {
              label: "Strictly necessary",
              detail:
                "Authentication/session, security, load balancing, and essential preferences. These are required to provide the service and do not depend on marketing consent.",
            },
            {
              label: "Functional (where used)",
              detail: `Remembering UI preferences or consent choices. Consent choice may be stored in local storage under a key such as “${COOKIE_CONSENT_KEY}”.`,
            },
            {
              label: "Analytics (non-essential)",
              detail:
                "Audience measurement and product improvement, only if you accept non-essential cookies via our consent banner.",
            },
            {
              label: "Payment-related",
              detail: `When you complete a purchase, ${PAYMENT_PROVIDER} and related payment infrastructure may set cookies or similar technologies under their own policies to process payments securely.`,
            },
          ]}
        />
      </section>

      <section>
        <SectionTitle index="3" title="Legal basis and Israeli / international rules" />
        <Prose>
          Strictly necessary cookies are used to perform the contract or for legitimate interests
          in securing and delivering the service, consistent with the Israeli Protection of Privacy
          Law and, where applicable, ePrivacy/GDPR rules. Non-essential analytics cookies rely on
          your consent, which you may refuse or withdraw without affecting core access.
        </Prose>
      </section>

      <section>
        <SectionTitle index="4" title="Retention" />
        <Prose>
          Session cookies are typically deleted when you close the browser. Persistent cookies and
          local storage entries are kept only as long as needed for their purpose—generally up to
          thirteen (13) months for analytics, unless a shorter period applies—or until you clear
          them or withdraw consent.
        </Prose>
      </section>

      <section>
        <SectionTitle index="5" title="Managing your preferences" />
        <Prose>
          You can accept or reject non-essential cookies via the cookie banner on our site. You can
          also change browser settings to block or delete cookies. Blocking strictly necessary
          cookies may prevent login or core features from working.
        </Prose>
        <Prose className="mt-3">
          To withdraw analytics consent after accepting, clear site data for {SITE_DOMAIN} or
          contact us and request reset of your consent preference. After clearing local storage for
          the consent key, the banner will appear again.
        </Prose>
      </section>

      <section>
        <SectionTitle index="6" title="Contact" />
        <Prose>For questions about cookies or related data processing:</Prose>
        <EntityContactCard attention="Privacy / cookies" />
      </section>
    </LegalDocLayout>
  );
}
