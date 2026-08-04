import React, { useMemo } from "react";
import { cn } from "@/lib/cn";

/**
 * Minimal, dependency-free markdown renderer for agent output: headings,
 * lists, code blocks, blockquotes, tables, hr, inline bold/italic/code/links.
 * Renders React elements only — no innerHTML, so untrusted content is safe.
 */

const INLINE_TOKEN =
  /(`[^`]+`|\*\*[^*]+\*\*|__[^_]+__|\*[^*\n]+\*|\[[^\]]+\]\(https?:\/\/[^)\s]+\))/g;

function renderInline(text: string): React.ReactNode[] {
  return text.split(INLINE_TOKEN).map((part, i) => {
    if (!part) return null;
    if (part.startsWith("`") && part.endsWith("`") && part.length > 2) {
      return (
        <code key={i} className="rounded bg-surface-overlay px-1 py-0.5 text-[0.9em] text-primary-light">
          {part.slice(1, -1)}
        </code>
      );
    }
    if ((part.startsWith("**") && part.endsWith("**")) || (part.startsWith("__") && part.endsWith("__"))) {
      return (
        <strong key={i} className="font-semibold text-text">
          {part.slice(2, -2)}
        </strong>
      );
    }
    if (part.startsWith("*") && part.endsWith("*") && part.length > 2) {
      return <em key={i}>{part.slice(1, -1)}</em>;
    }
    const link = part.match(/^\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)$/);
    if (link) {
      return (
        <a
          key={i}
          href={link[2]}
          target="_blank"
          rel="noreferrer noopener"
          className="text-primary-light underline underline-offset-2 hover:text-primary"
        >
          {link[1]}
        </a>
      );
    }
    return <React.Fragment key={i}>{part}</React.Fragment>;
  });
}

type Block =
  | { kind: "heading"; level: number; text: string }
  | { kind: "paragraph"; text: string }
  | { kind: "list"; ordered: boolean; items: string[] }
  | { kind: "code"; text: string }
  | { kind: "quote"; text: string }
  | { kind: "table"; rows: string[][] }
  | { kind: "hr" };

function parseBlocks(md: string): Block[] {
  const lines = (md || "").replace(/\r\n/g, "\n").split("\n");
  const blocks: Block[] = [];
  let paragraph: string[] = [];
  let list: { ordered: boolean; items: string[] } | null = null;
  let code: string[] | null = null;
  let table: string[][] | null = null;

  const flushParagraph = () => {
    if (paragraph.length) {
      blocks.push({ kind: "paragraph", text: paragraph.join(" ") });
      paragraph = [];
    }
  };
  const flushList = () => {
    if (list) {
      blocks.push({ kind: "list", ...list });
      list = null;
    }
  };
  const flushTable = () => {
    if (table) {
      blocks.push({ kind: "table", rows: table });
      table = null;
    }
  };

  for (const raw of lines) {
    if (code) {
      if (raw.trim().startsWith("```")) {
        blocks.push({ kind: "code", text: code.join("\n") });
        code = null;
      } else {
        code.push(raw);
      }
      continue;
    }

    const line = raw.trim();

    if (line.startsWith("```")) {
      flushParagraph();
      flushList();
      flushTable();
      code = [];
      continue;
    }
    if (!line) {
      flushParagraph();
      flushList();
      flushTable();
      continue;
    }
    if (line.startsWith("|") && line.endsWith("|")) {
      flushParagraph();
      flushList();
      const cells = line.slice(1, -1).split("|").map((c) => c.trim());
      if (cells.every((c) => /^:?-{2,}:?$/.test(c) || c === "")) continue;
      table = table ?? [];
      table.push(cells);
      continue;
    }
    flushTable();

    const heading = line.match(/^(#{1,4})\s+(.*)$/);
    if (heading) {
      flushParagraph();
      flushList();
      blocks.push({ kind: "heading", level: heading[1].length, text: heading[2] });
      continue;
    }
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(line)) {
      flushParagraph();
      flushList();
      blocks.push({ kind: "hr" });
      continue;
    }
    if (line.startsWith(">")) {
      flushParagraph();
      flushList();
      blocks.push({ kind: "quote", text: line.replace(/^>\s?/, "") });
      continue;
    }
    const bullet = line.match(/^[-*+]\s+(.*)$/);
    const ordered = line.match(/^\d+[.)]\s+(.*)$/);
    if (bullet || ordered) {
      flushParagraph();
      const isOrdered = Boolean(ordered);
      if (!list || list.ordered !== isOrdered) {
        flushList();
        list = { ordered: isOrdered, items: [] };
      }
      list.items.push((bullet ?? ordered)![1]);
      continue;
    }
    paragraph.push(line);
  }
  flushParagraph();
  flushList();
  flushTable();
  if (code) blocks.push({ kind: "code", text: code.join("\n") });
  return blocks;
}

const HEADING_STYLES: Record<number, string> = {
  1: "text-lg font-bold text-text mt-4 first:mt-0",
  2: "text-[15px] font-bold text-text mt-4 first:mt-0",
  3: "text-[13px] font-semibold text-text mt-3 first:mt-0",
  4: "text-xs font-semibold text-text mt-3 first:mt-0",
};

export function MarkdownView({ markdown, className }: { markdown: string; className?: string }) {
  const blocks = useMemo(() => parseBlocks(markdown), [markdown]);

  return (
    <div className={cn("space-y-2 text-xs leading-relaxed text-text-secondary", className)}>
      {blocks.map((block, i) => {
        switch (block.kind) {
          case "heading":
            return (
              <p key={i} className={HEADING_STYLES[block.level]}>
                {renderInline(block.text)}
              </p>
            );
          case "paragraph":
            return <p key={i}>{renderInline(block.text)}</p>;
          case "list":
            return block.ordered ? (
              <ol key={i} className="list-decimal space-y-1 pl-5">
                {block.items.map((item, j) => (
                  <li key={j}>{renderInline(item)}</li>
                ))}
              </ol>
            ) : (
              <ul key={i} className="list-disc space-y-1 pl-5">
                {block.items.map((item, j) => (
                  <li key={j}>{renderInline(item)}</li>
                ))}
              </ul>
            );
          case "code":
            return (
              <pre
                key={i}
                className="overflow-x-auto rounded-lg bg-bg-deep/70 px-3 py-2.5 font-mono text-[11px] leading-relaxed text-text-secondary"
              >
                {block.text}
              </pre>
            );
          case "quote":
            return (
              <blockquote key={i} className="border-l-2 border-primary/40 pl-3 italic">
                {renderInline(block.text)}
              </blockquote>
            );
          case "table":
            return (
              <div key={i} className="overflow-x-auto">
                <table className="w-full border-collapse text-[11px]">
                  <tbody>
                    {block.rows.map((row, r) => (
                      <tr key={r} className="border-b border-border/50">
                        {row.map((cell, c) =>
                          r === 0 ? (
                            <th key={c} className="px-2 py-1.5 text-left font-semibold text-text">
                              {renderInline(cell)}
                            </th>
                          ) : (
                            <td key={c} className="px-2 py-1.5">
                              {renderInline(cell)}
                            </td>
                          ),
                        )}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            );
          case "hr":
            return <hr key={i} className="border-border/60" />;
          default:
            return null;
        }
      })}
    </div>
  );
}
