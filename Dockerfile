# Build openclaw from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS openclaw-build

# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Pin to a known ref (tag/branch). If it doesn't exist, fall back to main.
ARG OPENCLAW_GIT_REF=main
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
# Apply to all extension package.json files to handle workspace protocol (workspace:*).
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
# The UI build may fail on some openclaw refs due to node:module being
# imported into a Vite browser bundle (createRequire not available).
# Make it non-fatal — the wrapper /setup page works independently, and
# the gateway API still functions without the control UI.
RUN pnpm ui:install && (pnpm ui:build || echo '[WARN] ui:build failed; gateway control UI will not be available')

# Prune dev dependencies and build artifacts to shrink the final image.
# Only dist/, production node_modules, and package.json files are needed at runtime.
RUN pnpm prune --prod 2>/dev/null || true \
  && rm -rf .git .cache .turbo .bun \
    src/ apps/ docs/ scripts/ benchmarks/ \
    **/.turbo **/tsconfig*.json **/vitest*.config* \
    **/jest.config* **/.eslint* **/.prettier* \
  && find . -name '*.map' -delete 2>/dev/null || true \
  && find . -name '*.d.ts' -not -path '*/dist/*' -delete 2>/dev/null || true


# Runtime image — use slim variant to save ~300MB
FROM node:22-bookworm-slim
ENV NODE_ENV=production

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy built openclaw (already pruned in build stage)
COPY --from=openclaw-build /openclaw /openclaw

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

COPY src ./src

# The wrapper listens on this port.
ENV OPENCLAW_PUBLIC_PORT=8080
ENV PORT=8080
EXPOSE 8080
CMD ["node", "src/server.js"]
