# Build stage
FROM node:18-alpine AS build-stage

WORKDIR /app

# Install TypeScript globally
RUN npm install -g typescript

# Debug: List contents before copy
RUN ls -la

# Copy package files from app directory
COPY app/package*.json ./

# Debug: List contents after copy
RUN ls -la

# Install dependencies
RUN npm install || exit 1

# Copy project files
COPY app/ .

# Build the Vue app (skip type checking for now)
RUN NODE_OPTIONS=--max-old-space-size=4096 npm run build --force || true

# Production stage
FROM ubuntu:latest

# Install required packages
RUN apt-get update && apt-get install -y \
    curl \
    nginx \
    && rm -rf /var/lib/apt/lists/*

# Install Ollama
RUN curl -fsSL https://ollama.com/install.sh | sh

# Set Ollama to listen on port 11436 (internal) instead of default 11434
ENV OLLAMA_HOST=127.0.0.1:11436

# Download the model (start ollama, pull model, stop ollama)
RUN OLLAMA_HOST=127.0.0.1:11436 ollama serve & \
    sleep 5 && \
    OLLAMA_HOST=127.0.0.1:11436 ollama pull deepseek-r1:1.5b && \
    pkill ollama && \
    sleep 2

# Copy built Vue files from build stage
COPY --from=build-stage /app/dist /usr/share/nginx/html

# Configure Nginx with CORS proxy for Ollama
RUN echo ' \
server { \
    listen 11435; \
    server_name _; \
    \
    location / { \
        proxy_pass http://127.0.0.1:11436; \
        proxy_http_version 1.1; \
        proxy_set_header Upgrade $http_upgrade; \
        proxy_set_header Connection "upgrade"; \
        proxy_set_header Host $host; \
        \
        # CORS headers \
        add_header Access-Control-Allow-Origin "*" always; \
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always; \
        add_header Access-Control-Allow-Headers "DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization" always; \
        add_header Access-Control-Expose-Headers "Content-Length,Content-Range" always; \
        \
        # Handle preflight requests \
        if ($request_method = OPTIONS) { \
            add_header Access-Control-Allow-Origin "*" always; \
            add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always; \
            add_header Access-Control-Allow-Headers "DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization" always; \
            add_header Access-Control-Max-Age "1728000" always; \
            add_header Content-Type "text/plain charset=UTF-8"; \
            add_header Content-Length 0; \
            return 204; \
        } \
    } \
} \
\
server { \
    listen 80; \
    server_name _; \
    \
    location / { \
        root /usr/share/nginx/html; \
        try_files $uri $uri/ /index.html; \
    } \
}' > /etc/nginx/sites-available/default \
&& ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

# Remove the default nginx config if it exists
RUN rm -f /etc/nginx/conf.d/default.conf

# Expose ports
EXPOSE 80 11435

# Start both nginx and ollama
CMD service nginx start && OLLAMA_HOST=127.0.0.1:11436 ollama serve