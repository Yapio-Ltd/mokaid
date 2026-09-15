import { TextMorph } from "@/components/ui/text-morph";
import { cn } from "@/lib/cn";

const hireSpecialists = [
  "developers",
  "designers",
  "researchers",
  "marketers",
  "legal experts",
  "data scientists",
  "product managers",
  "DevOps engineers",
  "writers",
  "security analysts",
  "finance analysts",
  "support agents",
];

type Props = {
  /** On mobile, hide once the user leaves the hero so it doesn't cover scrollytelling. */
  visible?: boolean;
};

/** Part of the hero flow: every rotating phrase has reserved space. */
export function HireOverlay({ visible = true }: Props) {
  return (
    <p data-hero-intro className={cn("mk-hero-hire", !visible && "hidden")} aria-hidden={!visible}>
      <span className="mk-hero-hire-static">You can now hire AI&nbsp;</span>
      <TextMorph words={hireSpecialists} interval={2600} className="mk-hero-hire-morph" />
    </p>
  );
}
