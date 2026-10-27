FROM node:22-slim AS build
WORKDIR /service
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev
FROM node:22-slim
ENV NODE_ENV=production
WORKDIR /service
COPY --from=build /service/node_modules ./node_modules
COPY --from=build /service/dist ./dist
COPY package.json ./
USER node
CMD ["node", "dist/index.js"]
