# --- Shared: Vite build (no browser; fast for CI) ---
FROM node:22-slim AS assets

WORKDIR /repo

COPY package.json package-lock.json* ./
COPY apps/web/package.json ./apps/web/
COPY packages/design-tokens/package.json ./packages/design-tokens/
COPY packages/shared-types/package.json ./packages/shared-types/

RUN npm install

COPY packages ./packages
COPY apps/web ./apps/web
# nginx conf is only needed at runtime, but keep this stage pure web sources

ARG VITE_API_URL=
ARG VITE_WS_URL=/socket
ENV VITE_API_URL=$VITE_API_URL VITE_WS_URL=$VITE_WS_URL
ENV NODE_OPTIONS=--max-old-space-size=1536

RUN npm run build --workspace=apps/web \
    && cp apps/web/dist/index.html apps/web/dist/spa.html

# --- CI runtime: SPA shell only (no Playwright pull / prerender) ---
FROM nginx:1.27-alpine AS runtime-ci

COPY infra/docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=assets /repo/apps/web/dist /usr/share/nginx/html

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]

# --- SEO prerender (deploy only): Chromium+deps preinstalled ---
FROM mcr.microsoft.com/playwright:v1.62.1-jammy AS seo

WORKDIR /repo
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV NODE_OPTIONS=--max-old-space-size=1536

COPY --from=assets /repo /repo

RUN npm run prerender --workspace=apps/web

# --- Production runtime (default): prerendered marketing HTML + SPA fallback ---
FROM nginx:1.27-alpine AS runtime

COPY infra/docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=seo /repo/apps/web/dist /usr/share/nginx/html

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
