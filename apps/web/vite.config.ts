import { defineConfig, loadEnv, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";

/** ALB sticky-session cookies on localhost blow past Node's 16KB header limit (HTTP 431). */
function stripDevCookies(): Plugin {
  return {
    name: "strip-dev-cookies",
    configureServer(server) {
      server.middlewares.use((req, _res, next) => {
        if (req.url?.startsWith("/api") || req.url?.startsWith("/socket")) {
          delete req.headers.cookie;
          delete req.headers.origin;
          delete req.headers.referer;
        }
        next();
      });
    },
  };
}

/** Prevent ALB sticky-session cookies from accumulating on localhost (causes HTTP 431). */
function stripProxyCookies(proxy: { on: (event: string, handler: (...args: unknown[]) => void) => void }) {
  proxy.on("proxyReq", (proxyReq) => {
    const req = proxyReq as { removeHeader: (name: string) => void };
    req.removeHeader("cookie");
    req.removeHeader("origin");
    req.removeHeader("referer");
  });
  proxy.on("proxyRes", (proxyRes) => {
    const res = proxyRes as { headers: Record<string, string | string[] | undefined> };
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
    exclude: ["recast-navigation", "@recast-navigation/core", "@recast-navigation/generators", "@recast-navigation/wasm"],
  },
  server: {
    port: 5173,
    host: true,
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
          (dep) => !dep.includes("babylon") && !dep.includes("charts") && !dep.includes("recharts"),
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
    environment: "jsdom",
    globals: true,
    setupFiles: ["src/test/setup.ts"],
  },
};
});
