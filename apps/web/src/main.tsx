import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider } from "@tanstack/react-router";
import { router } from "./router";
import "./styles/globals.css";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 15_000,
      retry: 1,
      refetchOnWindowFocus: false,
    },
  },
});

// Account changes in another tab also replace the HttpOnly cookie. Reload all
// query/socket state together so the old account cannot remain visible or send
// writes with a stale CSRF marker.
window.addEventListener("storage", (event) => {
  if (event.key !== "mokaid-auth") return;
  try {
    const previous = JSON.parse(event.oldValue ?? "null")?.state?.token ?? null;
    const next = JSON.parse(event.newValue ?? "null")?.state?.token ?? null;
    if (previous !== next) window.location.reload();
  } catch {
    // Invalid storage is handled by the normal authentication check on reload.
  }
});

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </StrictMode>,
);
