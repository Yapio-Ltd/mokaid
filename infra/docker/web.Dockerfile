# --- Build stage ---
FROM node:22-slim AS build

WORKDIR /repo

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

RUN npm run build --workspace=apps/web

# Prerender the public routes to static HTML (SEO: crawlers get real content).
RUN npx playwright install --with-deps chromium \
    && npm run prerender --workspace=apps/web

# --- Runtime stage (static file server) ---
FROM nginx:1.27-alpine AS runtime

COPY infra/docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /repo/apps/web/dist /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
