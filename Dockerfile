FROM steamcmd/steamcmd:debian AS base
LABEL maintainer="git@luxusburg.lu"

ARG DEBIAN_FRONTEND="noninteractive"
VOLUME ["/home/cubic/server_files"]

# Set environment variables
ENV USER=cubic
ENV HOME=/home/$USER
ENV TZ='Europe/Berlin'
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Install wine, xvfb, and xauth (required for xvfb-run)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        jq \
        python3 \
        wine \
        xvfb \
        xauth \
        tzdata \
        locales \
        sudo && \
    rm -rf /var/lib/apt/lists/*

RUN echo 'export LC_ALL=$LC_ALL' >> /etc/profile.d/locale.sh && \
    sed -i 's|LANG=C.UTF-8|LANG=$LANG|' /etc/profile.d/locale.sh

# add new user
RUN groupadd -g ${PGID:-1000} $USER && \
    useradd -d $HOME -u ${PUID:-1000} -g $USER $USER && \
    mkdir -p $HOME && \
    chown $USER:$USER $HOME

RUN echo "$USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER && \
    chmod 0440 /etc/sudoers.d/$USER

USER $USER
WORKDIR $HOME

# Copy batch files and give execute rights. webui.py/webui.sh ride along into
# $HOME/scripts, which is also where webui.py looks for backup.sh.
# python3 above is only needed for the optional web admin UI (WEBUI=true).
ADD --chown=$USER:$USER ./files $HOME/scripts
RUN chmod +x $HOME/scripts/*.sh

# Build metadata (CI passes --build-arg VERSION=<git sha>)
ARG VERSION=dev
RUN echo "${VERSION}" > $HOME/scripts/VERSION
LABEL org.opencontainers.image.title="docker-cubic-odyssey" \
      org.opencontainers.image.description="Cubic Odyssey dedicated server (wine) with backups, scheduler and optional admin web UI" \
      org.opencontainers.image.source="https://github.com/luxusburg/docker-cubic-odyssey" \
      org.opencontainers.image.revision="${VERSION}"

ENTRYPOINT ["/bin/bash", "/home/cubic/scripts/entrypoint.sh"]
CMD ["/home/cubic/scripts/start.sh"]

# Cron was replaced by the in-process backup scheduler (files/scheduler.sh).
# This stage keeps :non_cron semantics: the marker file turns backups ON by
# default; plain :base (published as :non_cron) leaves them OFF. BACKUPS=...
# env always overrides either default (see start.sh).
FROM base AS image-cron
RUN touch /home/cubic/.image_cron && chown cubic:cubic /home/cubic/.image_cron
