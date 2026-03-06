#!/bin/sh
nginx

# Pass --transport and --server-url to pre-configure the Inspector UI
# via the proxy's /config endpoint (no query params needed in the URL)
ARGS=""
if [ -n "$MCP_SERVER_URL" ]; then
  ARGS="--transport streamable-http --server-url $MCP_SERVER_URL"
fi

exec npx @modelcontextprotocol/inspector@0.20.0 $ARGS
