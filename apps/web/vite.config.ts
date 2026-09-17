import { defineConfig, loadEnv, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";

/** Remove only load-balancer affinity cookies; preserve authentication and CSRF headers. */
function withoutAlbCookies(cookie: string | undefined): string | undefined {
  const kept = cookie
    ?.split(";")
    .map((part) => part.trim())
    .filter((part) => !/^AWSALB[^=]*=/.test(part));
  return kept?.length ? kept.join("; ") : undefined;
}

function stripDevCookies(): Plugin {
  return {
    name: "strip-alb-affinity-cookies",
    configureServer(server) {
      server.middlewares.use((req, _res, next) => {
        if (req.url?.startsWith("/api") || req.url?.startsWith("/socket")) {
          const cookie = withoutAlbCookies(req.headers.cookie);
          if (cookie) req.headers.cookie = cookie;
          else delete req.headers.cookie;
        }
        next();
      });
    },
  };
}

function stripProxyCookies(proxy: {
  on: (event: string, handler: (...args: unknown[]) => void) => void;
}) {
  const cleanRequest = (proxyReq: unknown) => {
    const req = proxyReq as {
      getHeader: (name: string) => string | undefined;
      setHeader: (name: string, value: string) => void;
      removeHeader: (name: string) => void;
    };
    const cookie = withoutAlbCookies(req.getHeader("cookie"));
    if (cookie) req.setHeader("cookie", cookie);
    else req.removeHeader("cookie");
  };
  proxy.on("proxyReq", cleanRequest);
  proxy.on("proxyReqWs", cleanRequest);
  proxy.on("proxyRes", (proxyRes) => {
    const res = proxyRes as { headers: Record<string, string | string[] | undefined> };
    const cookies = res.headers["set-cookie"];
    if (Array.isArray(cookies))
      res.headers["set-cookie"] = cookies.filter((cookie) => !/^AWSALB[^=]*=/.test(cookie));
    else if (typeof cookies === "string" && /^AWSALB[^=]*=/.test(cookies))
      delete res.headers["set-cookie"];
  });
}

function devProxy(target: string, ws = false) {
  return {
    target,
    changeOrigin: true,
    ws,
    configure: stripProxyCookies,
  };
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "");
  const proxyTarget = env.VITE_DEV_PROXY_TARGET || "http://localhost:4000";

  return {
    plugins: [react(), stripDevCookies()],
    resolve: {
      alias: {
        "@": fileURLToPath(new URL("./src", import.meta.url)),
      },
    },
    optimizeDeps: {
      // recast-navigation ships ESM + WASM; prebundle breaks init in Vite.
      exclude: [
        "recast-navigation",
        "@recast-navigation/core",
        "@recast-navigation/generators",
        "@recast-navigation/wasm",
      ],
    },
    server: {
      port: 5173,
      // Development is local by default; explicit --host remains available for containers.
      host: "127.0.0.1",
      proxy: {
        "/api": devProxy(proxyTarget),
        "/socket": devProxy(proxyTarget, true),
      },
    },
    build: {
      target: "es2022",
      sourcemap: false,
      modulePreload: {
        // Avoid eagerly fetching heavy async chunks (Babylon / charts) on the landing.
        resolveDependencies: (_filename, deps) =>
          deps.filter(
            (dep) =>
              !dep.includes("babylon") && !dep.includes("charts") && !dep.includes("recharts"),
          ),
      },
      rollupOptions: {
        output: {
          /**
           * Babylon/charts stay out of manualChunks so they are only pulled by
           * dynamic import() consumers (office / agent preview / analytics).
           */
          manualChunks(id) {
            if (!id.includes("node_modules")) return;
            if (id.includes("gsap") || id.includes("/lenis")) return "gsap";
            if (id.includes("framer-motion")) return "motion";
            if (
              id.includes("/react/") ||
              id.includes("/react-dom/") ||
              id.includes("@tanstack/react-query") ||
              id.includes("@tanstack/react-router") ||
              id.includes("@tanstack/react-store") ||
              id.includes("@tanstack/history")
            ) {
              return "vendor";
            }
          },
        },
      },
    },
    test: {
      include: ["src/**/*.{test,spec}.{ts,tsx}"],
      environment: "jsdom",
      globals: true,
      setupFiles: ["src/test/setup.ts"],
    },
  };
});
