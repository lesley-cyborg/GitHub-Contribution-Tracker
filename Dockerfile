# ==========================================
# STAGE 1: BUILD (Has tools, but stays in cache)
# ==========================================
FROM node:25-slim AS builder

WORKDIR /app

# Copy package files first for Docker layer caching
COPY package.json package-lock.json ./
RUN npm ci

# Copy source code and build
COPY . .
RUN npm run build

# ==========================================
# STAGE 2: RUNTIME (Secure, Distroless, Minimal)
# ==========================================
# Google's distroless image for Node 20 (Debian 12 base)
# Contains ONLY Node.js and the app. No shell, no apk, no apt.
FROM gcr.io/distroless/nodejs20-debian12

WORKDIR /app

# Copy ONLY the production-ready standalone files from the builder.
# This places server.js and the pruned node_modules directly in /app/
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static

# Set environment variables for Next.js (modern syntax avoids warnings)
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"

# The distroless image entrypoint is already 'node', so we just pass the file.
CMD ["server.js"]