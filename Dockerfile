FROM node:24-bookworm-slim

ARG PI_PACKAGE_VERSION=latest
ARG AGENT_BROWSER_VERSION=latest

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        chromium \
        curl \
        git \
        jq \
        procps \
        ripgrep \
        util-linux \
        xdg-utils \
        zsh \
    && rm -rf /var/lib/apt/lists/*

# Pi's documentation recommends disabling npm lifecycle scripts for its install.
RUN npm install --global --ignore-scripts \
        "@earendil-works/pi-coding-agent@${PI_PACKAGE_VERSION}" \
    && npm install --global --allow-scripts=agent-browser \
        "agent-browser@${AGENT_BROWSER_VERSION}"

USER node
ENV HOME=/home/node
ENV PI_CODING_AGENT_SESSION_DIR=/home/node/.pi/agent/sessions
ENV AGENT_BROWSER_PROFILE=/home/node/.agent-browser/profile
ENV AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium

USER root
RUN mkdir -p /home/node/.pi/agent /home/node/.agent-browser \
    && chown -R node:node /home/node/.pi /home/node/.agent-browser

COPY bin/pi-session-log /usr/local/bin/pi-session-log
COPY bin/pi-session-forwarder /usr/local/bin/pi-session-forwarder
COPY bin/pi-session-format /usr/local/bin/pi-session-format
COPY bin/pi-state-copy /usr/local/bin/pi-state-copy
COPY bin/pi-shell-launch /usr/local/bin/pi-shell-launch
RUN chmod 0755 /usr/local/bin/pi-session-log /usr/local/bin/pi-session-forwarder /usr/local/bin/pi-session-format /usr/local/bin/pi-state-copy /usr/local/bin/pi-shell-launch

USER node

WORKDIR /workspace

CMD ["pi"]
