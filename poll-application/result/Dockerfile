FROM node:24-slim

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY . .

USER 1000

EXPOSE 80

CMD ["node", "server.js"]
