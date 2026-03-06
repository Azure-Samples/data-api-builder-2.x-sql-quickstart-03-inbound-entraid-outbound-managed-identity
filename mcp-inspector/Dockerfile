FROM node:22-alpine
RUN npm install -g @modelcontextprotocol/inspector@0.20.0
RUN apk add --no-cache nginx
COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENV DANGEROUSLY_OMIT_AUTH=true
ENV MCP_AUTO_OPEN_ENABLED=false
ENV HOST=0.0.0.0
EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
