import type { MouseEvent } from "react";

/** A link to the page already open should still be useful from its footer. */
export function scrollCurrentPageToTop(event: MouseEvent<HTMLAnchorElement>) {
  if (
    event.defaultPrevented ||
    event.button !== 0 ||
    event.metaKey ||
    event.ctrlKey ||
    event.shiftKey ||
    event.altKey
  )
    return;
  const destination = new URL(event.currentTarget.href);
  if (
    destination.origin !== window.location.origin ||
    destination.hash ||
    destination.pathname !== window.location.pathname ||
    destination.search !== window.location.search
  )
    return;
  window.scrollTo({ top: 0, behavior: "instant" });
}
