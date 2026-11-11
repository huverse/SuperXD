# 构建：swc 编译到 dist；运行镜像只含生产依赖与编译产物，以非 root 用户运行，进程时区固定 UTC。
# 正式部署用流水线构建的镜像（.github/workflows/relay-image.yml），服务器只加载，见 README「部署」。
# 基础镜像按摘要固定（标签只为好读）：升级时两处 FROM 一起改，摘要取多架构索引的 sha256（Docker Hub 标签页或 docker buildx imagetools inspect）。
FROM node:24.22.2-alpine3.24@sha256:a34ab6d7f6f4813f4d0c5469d74685604b962fbdbf5793a7bc7b4998ecb867c8 AS build
# 国内服务器可传 NPM_REGISTRY=https://registry.npmmirror.com（锁文件里的 npmjs 地址会被替换为该源，版本与校验和不变）。
ARG NPM_REGISTRY=https://registry.npmjs.org
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --registry=$NPM_REGISTRY
COPY .swcrc tsconfig.json ./
COPY src ./src
# 构建后立即试加载编译产物：类型导入被编译成运行时导入等问题在这里就失败，不会带到线上。
RUN npm run build && npm run smoke

FROM node:24.22.2-alpine3.24@sha256:a34ab6d7f6f4813f4d0c5469d74685604b962fbdbf5793a7bc7b4998ecb867c8
ARG NPM_REGISTRY=https://registry.npmjs.org
ENV NODE_ENV=production TZ=UTC
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --registry=$NPM_REGISTRY && npm cache clean --force
COPY --from=build /app/dist ./dist
# 构建版本：流水线传提交号，/v1/health 原样返回；本地构建不传即为 dev。放在最后，换提交不让前面的依赖层失效。
ARG RELAY_BUILD_VERSION=dev
ENV RELAY_BUILD_VERSION=$RELAY_BUILD_VERSION
USER node
EXPOSE 8080
# 健康检查：用镜像自带的 busybox wget 请求本机 /v1/health（3 秒超时），不另起 node 进程；端口取运行时的 RELAY_PORT。
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD wget -q -T 3 -O /dev/null "http://127.0.0.1:${RELAY_PORT}/v1/health" || exit 1
CMD ["node", "dist/main.js"]
