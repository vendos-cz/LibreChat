# Outlook/Microsoft 365 MCP server (softeria/ms-365-mcp-server).
#
# Upstream publishes no image, so the pinned npm package is installed into a
# plain node:24-alpine. The version is a build arg: bumping it is a one-line
# change plus a redeploy.
#
# The server runs in HTTP mode and takes the Microsoft Graph token from each
# request's `Authorization: Bearer` header, which is what LibreChat's OBO
# exchange puts there. No credentials are cached, so the container needs no
# volume; it only writes its own logs to $HOME, which go with the container.
FROM node:24-alpine

ARG MS365_MCP_VERSION=0.149.1

RUN npm install -g "@softeria/ms-365-mcp-server@${MS365_MCP_VERSION}" \
  && npm cache clean --force

USER node

ENTRYPOINT ["ms-365-mcp-server"]
