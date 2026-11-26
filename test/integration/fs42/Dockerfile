# FS42 sandbox (catalog/schedule builds only; no player). Never mount real
# media or a production confs/ or runtime/ into it.
FROM debian:trixie-slim

ARG FS42_REPO=https://github.com/shane-mason/FieldStation42
ARG FS42_SHA=c313f7dd622991a7ef58b46fa7c24d6b11037270

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TZ=America/New_York

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git python3 python3-venv python3-dev build-essential \
      ffmpeg sqlite3 tzdata jq curl python3-tk \
    && rm -rf /var/lib/apt/lists/*

RUN git clone "$FS42_REPO" /opt/fs42 \
 && git -C /opt/fs42 checkout --detach "$FS42_SHA" \
 && test "$(git -C /opt/fs42 rev-parse HEAD)" = "$FS42_SHA"

WORKDIR /opt/fs42
COPY requirements.lock /tmp/requirements.lock
# An empty requirements.lock installs upstream's unpinned list (used by `make fs42-lock`).
RUN python3 -m venv env \
 && if [ -s /tmp/requirements.lock ]; then \
      env/bin/pip install --no-cache-dir -r /tmp/requirements.lock; \
    else \
      env/bin/pip install --no-cache-dir -r install/requirements.in; \
    fi \
 && env/bin/pip freeze --all > /opt/fs42-freeze.txt \
 && env/bin/pip install --no-cache-dir pytest==9.0.1

RUN mkdir -p runtime catalog confs \
 && for f in static.mp4 standby.png brb.png off_air_pattern.mp4 signoff.mp4; do cp docs/$f runtime/; done \
 && touch runtime/channel.socket

ENTRYPOINT []
CMD ["bash"]
