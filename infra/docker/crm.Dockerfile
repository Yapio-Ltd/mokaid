# --- Build stage ---
FROM node:22-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5 AS build

WORKDIR /repo

COPY package.json package-lock.json* ./
COPY apps/crm/package.json ./apps/crm/
COPY packages/design-tokens/package.json ./packages/design-tokens/
COPY packages/shared-types/package.json ./packages/shared-types/

RUN npm ci

COPY apps/crm ./apps/crm

ARG NEXT_PUBLIC_API_URL=
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_OPTIONS=--max-old-space-size=1536

RUN npm run build --workspace=apps/crm

# --- Runtime stage (Next.js standalone) ---
FROM node:22-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5 AS runtime

# The standalone server runs directly with Node: build/install tools are not
# runtime dependencies. Remove their bundled dependency trees, not just shims.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends libpcre2-8-0 \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' libpcre2-8-0)" ge '10.42-1+deb12u1' \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
    && rm -f /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
    && ! command -v npm && ! command -v npx && ! command -v corepack

WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3001
ENV HOSTNAME=0.0.0.0

# Standalone output layout: apps/crm/.next/standalone contains server.js at apps/crm/server.js
COPY --from=build /repo/apps/crm/.next/standalone ./
COPY --from=build /repo/apps/crm/.next/static ./apps/crm/.next/static
COPY --from=build /repo/apps/crm/public ./apps/crm/public

EXPOSE 3001

CMD ["node", "apps/crm/server.js"]
