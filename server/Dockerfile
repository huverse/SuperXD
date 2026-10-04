# 构建：swc 编译到 dist；运行镜像只含生产依赖与编译产物，以非 root 用户运行，进程时区固定 UTC。
FROM node:24-alpine AS build
# 国内服务器可传 NPM_REGISTRY=https://registry.npmmirror.com（锁文件里的 npmjs 地址会被替换为该源，版本与校验和不变）。
ARG NPM_REGISTRY=https://registry.npmjs.org
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --registry=$NPM_REGISTRY
COPY .swcrc tsconfig.json ./
COPY src ./src
# 构建后立即试加载编译产物：类型导入被编译成运行时导入等问题在这里就失败，不会带到线上。
RUN npm run build && npm run smoke

FROM node:24-alpine
ARG NPM_REGISTRY=https://registry.npmjs.org
ENV NODE_ENV=production TZ=UTC
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --registry=$NPM_REGISTRY && npm cache clean --force
COPY --from=build /app/dist ./dist
USER node
EXPOSE 8080
CMD ["node", "dist/main.js"]
