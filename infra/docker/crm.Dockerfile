# --- Build stage ---
FROM node:22-slim AS build

WORKDIR /repo

COPY package.json package-lock.json* ./
COPY apps/crm/package.json ./apps/crm/
COPY packages/design-tokens/package.json ./packages/design-tokens/
COPY packages/shared-types/package.json ./packages/shared-types/

RUN npm install

COPY apps/crm ./apps/crm

ARG NEXT_PUBLIC_API_URL=
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_OPTIONS=--max-old-space-size=1536

RUN npm run build --workspace=apps/crm

# --- Runtime stage (Next.js standalone) ---
FROM node:22-slim AS runtime

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
