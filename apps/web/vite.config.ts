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
    rollupOptions: {
      output: {
        manualChunks: {
          babylon: ["@babylonjs/core"],
          charts: ["recharts"],
          vendor: ["react", "react-dom", "@tanstack/react-query", "@tanstack/react-router"],
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
