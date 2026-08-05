# --- Build stage ---
# Playwright image ships Chromium + system libs so prerender works without a
# multi-minute `playwright install --with-deps` on node:slim (which hung CI).
FROM mcr.microsoft.com/playwright:v1.62.1-jammy AS build

WORKDIR /repo

ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

COPY package.json package-lock.json* ./
COPY apps/web/package.json ./apps/web/
COPY packages/design-tokens/package.json ./packages/design-tokens/
COPY packages/shared-types/package.json ./packages/shared-types/

RUN npm install

COPY packages ./packages
COPY apps/web ./apps/web

ARG VITE_API_URL=
ARG VITE_WS_URL=/socket
ENV VITE_API_URL=$VITE_API_URL VITE_WS_URL=$VITE_WS_URL
ENV NODE_OPTIONS=--max-old-space-size=1536

RUN npm run build --workspace=apps/web \
    && npm run prerender --workspace=apps/web

# --- Runtime stage (static file server) ---
FROM nginx:1.27-alpine AS runtime

COPY infra/docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /repo/apps/web/dist /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
