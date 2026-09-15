# --- Shared: Vite build (no browser; fast for CI) ---
FROM --platform=$BUILDPLATFORM node:22-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5 AS assets

WORKDIR /repo

COPY package.json package-lock.json* ./
COPY apps/web/package.json ./apps/web/
COPY packages/design-tokens/package.json ./packages/design-tokens/
COPY packages/shared-types/package.json ./packages/shared-types/

RUN npm ci

COPY packages ./packages
COPY apps/web ./apps/web

ARG VITE_API_URL=
ARG VITE_WS_URL=/socket
ENV VITE_API_URL=$VITE_API_URL VITE_WS_URL=$VITE_WS_URL
ENV NODE_OPTIONS=--max-old-space-size=1536

RUN npm run build --workspace=apps/web \
    && cp apps/web/dist/index.html apps/web/dist/spa.html

# --- Shared runtime: patched distro package on the pinned nginx base ---
FROM nginx:1.30.4-alpine@sha256:dc5069ad14f19660b141b21236140b91656bf89bbc3e2417c70ae650cd66104c AS nginx-runtime

# The base contains util-linux/libuuid 2.42.1. Keep the distro's signed
# security update in both runtime targets; fail if the patch is unavailable.
RUN apk add --no-cache --upgrade 'libuuid>=2.42.3-r1' \
    && apk info --exists 'libuuid>=2.42.3-r1'

# --- CI runtime: SPA shell only (no Playwright pull / prerender) ---
FROM nginx-runtime AS runtime-ci

COPY infra/docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=assets /repo/apps/web/dist /usr/share/nginx/html

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]

# --- SEO prerender (deploy): Chromium+deps preinstalled ---
# Render on the builder's native architecture: snapshots are portable HTML.
# A failed prerender MUST fail the deploy; never silently publish an empty SPA.
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/playwright:v1.62.1-jammy@sha256:b3251f7ff1a9fa559a28d1c67eaa15fc1a9800f7845e82756caea7842967f615 AS seo

WORKDIR /repo
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV NODE_OPTIONS=--max-old-space-size=1536

COPY --from=assets /repo /repo

RUN npm run prerender --workspace=apps/web

# --- Production runtime (default) ---
FROM nginx-runtime AS runtime

COPY infra/docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=seo /repo/apps/web/dist /usr/share/nginx/html

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
