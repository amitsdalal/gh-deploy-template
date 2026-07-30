# syntax=docker/dockerfile:1
#
# Next.js app served by PM2 in cluster mode.
#
# TEMPLATE -- adjust NODE_VERSION / TZ / APP_PORT for the project. Everything
# else should work unchanged for a standard Next.js app using the pages router.
#
# Single stage on purpose: Next inlines NEXT_PUBLIC_* into the client bundle at
# build time, so .env must be present in the build context. If the project ever
# introduces a genuinely server-only secret, split this into a multi-stage build
# so .env cannot survive into the final image.

ARG NODE_VERSION=24
FROM node:${NODE_VERSION}-alpine
LABEL org.opencontainers.image.source="https://github.com/OWNER/REPO"

WORKDIR /app

# Deliberately NOT `npm install -g npm@latest`.
#   * npm 12 disables git-protocol dependencies; a project with a `github:`
#     dependency fails with EALLOWGIT.
#   * "latest" makes the build non-deterministic -- it changes under you.
# Use the npm bundled with the pinned Node image, and pin pm2.
RUN npm install -g pm2@6

# git is only needed if package.json has a `github:` / `git+` dependency.
ARG TZ=Asia/Kolkata
RUN apk --no-cache add tzdata git \
 && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
 && echo $TZ > /etc/timezone
ENV TZ=${TZ}

RUN addgroup -g 1001 -S nodejs && adduser -S nextjs -u 1001

# the sidecar proxy reads this from a shared path; see docker-compose*.yaml
RUN mkdir -p /etc/nginx/conf.d
COPY nginx.conf /etc/nginx/conf.d/default.conf

COPY package*.json ./
# --legacy-peer-deps only if the project has an unresolved peer conflict.
# Remove it once the dependency tree is clean.
RUN if [ -f package-lock.json ]; then npm ci --legacy-peer-deps; \
    else npm install --legacy-peer-deps; fi

COPY . .

# NEXT_PUBLIC_* are inlined here, from the .env written by CI before the build.
RUN npm run build

ARG APP_PORT=3000
ENV NODE_ENV=production
ENV PORT=${APP_PORT}
EXPOSE ${APP_PORT}

# No `--env production`: pm2-runtime forwards the flag to the script and
# `next start` rejects it, crash-looping the container. NODE_ENV is set above.
CMD ["pm2-runtime", "start", "process.yml"]
