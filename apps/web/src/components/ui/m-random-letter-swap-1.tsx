import { RandomLetterSwap } from "@/components/ui/random-letter-swap";

const links = ["Home", "Work", "About", "Blog", "Contact"];

/** Demo / reference usage of RandomLetterSwap as a nav row. */
export default function RandomLetterSwapNav() {
  return (
    <div className="flex min-h-[12.5rem] items-center justify-center px-6">
      <nav className="flex items-center gap-8">
        {links.map((link) => (
          <RandomLetterSwap
            className="cursor-pointer text-sm font-medium text-text-muted hover:text-text"
            key={link}
            label={link}
            staggerDuration={0.025}
            transition={{ duration: 0.6, type: "spring" }}
          />
        ))}
      </nav>
    </div>
  );
}
