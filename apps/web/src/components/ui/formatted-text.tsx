import { Fragment } from "react";
import { cn } from "@/lib/cn";

const BOLD_SEGMENT = /(\*\*.+?\*\*)/g;

/** Renders plain text with inline `**bold**` markdown segments. */
export function FormattedText({
  text,
  className,
}: {
  text: string;
  className?: string;
}) {
  const parts = text.split(BOLD_SEGMENT);

  return (
    <p className={cn("whitespace-pre-wrap", className)}>
      {parts.map((part, index) => {
        if (part.startsWith("**") && part.endsWith("**") && part.length > 4) {
          return (
            <strong key={index} className="font-semibold">
              {part.slice(2, -2)}
            </strong>
          );
        }
        return <Fragment key={index}>{part}</Fragment>;
      })}
    </p>
  );
}
