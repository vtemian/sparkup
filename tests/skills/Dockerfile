# A throwaway box for testing this repo's skills with the real Claude Code CLI.
#
# The container is the isolation: the agent under test gets no conversation
# history, no host filesystem and no real hardware, only the faked box and
# whichever skills the arm under test mounted. That is what makes a pass mean
# something.
FROM node:22-slim

# gawk and make because the fake box answers `make report` with the real role's
# formatting rather than an approximation of it.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git gawk make jq \
    && rm -rf /var/lib/apt/lists/*

# Pinned, because the CLI is the thing under test: on `latest` plus a cached npm
# layer, one machine tests a months-old CLI and another tests today's, and a
# skill-discovery change produces a result nobody can reproduce. Bump it
# deliberately, the way every other version in this repo is bumped.
ARG CLAUDE_CODE_VERSION=2.1.226
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# The fake nvidia-smi goes first on PATH, so an agent that reaches for it gets
# the instrument that lies, exactly as it would on the box.
ENV PATH=/fakebox/bin:$PATH

# Not root: the CLI refuses --dangerously-skip-permissions when it has root
# privileges, and without that flag a headless agent cannot run the commands the
# skill tells it to run. The node image ships this user at uid 1000.
RUN mkdir -p /work && chown node:node /work
USER node
WORKDIR /work

# `bash -c`, deliberately not `-lc`: a login shell re-reads /etc/profile, which
# rebuilds PATH from scratch and drops /fakebox/bin, so the fake nvidia-smi
# disappears and the agent under test sees no GPU at all.
ENTRYPOINT ["/usr/bin/env", "bash", "-c"]
