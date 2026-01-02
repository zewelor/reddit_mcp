FROM ruby:4.0.0-slim AS base

RUN groupadd -g 1000 app && \
    useradd -u 1000 -g app -d /app -s /bin/false app

WORKDIR /app

# We mount whole . dir into app, so vendor/bundle would get overwritten
ENV BUNDLE_PATH=/bundle \
    BUNDLE_BIN=/bundle/bin \
    GEM_HOME=/bundle

ENV PATH="${BUNDLE_BIN}:${PATH}"

FROM base AS basedev

ARG DEV_PACKAGES="build-essential"

ENV BUNDLE_AUTO_INSTALL=true

# hadolint ignore=SC2086,DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    $DEV_PACKAGES && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

FROM basedev AS dev

RUN mkdir -p "$BUNDLE_PATH" && \
    chown -R app:app "$BUNDLE_PATH"

USER app

FROM basedev AS baseliveci

# hadolint ignore=DL3045
COPY --chown=app:app Gemfile Gemfile.lock ./

FROM baseliveci AS ci

# hadolint ignore=SC2086
RUN mkdir -p $BUNDLE_PATH && \
    chown -R app $BUNDLE_PATH

RUN bundle install "-j$(nproc)" --retry 3 && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

FROM baseliveci AS live_builder

ENV BUNDLE_WITHOUT="development:test"

RUN bundle install "-j$(nproc)" --retry 3 && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

FROM base AS live

ENV BUNDLE_DEPLOYMENT="1" \
    BUNDLE_WITHOUT="development:test"

# Minimize attack surface by removing unnecessary packages
# Keep: libc6, libssl3t64, libgmp10, zlib1g, ca-certificates, libyaml, libffi, openssl, coreutils, dash
# hadolint ignore=DL3027
RUN rm -rf /var/lib/apt/lists/* /var/cache/* /var/log/* \
           /usr/share/doc /usr/share/man /usr/share/info /usr/share/lintian \
           /usr/share/zsh /usr/share/bash-completion \
           /tmp/* /root/.cache /root/.bundle && \
    dpkg --purge --force-remove-essential --force-depends \
        # Package management (not needed at runtime)
        apt dpkg debianutils debian-archive-keyring debconf \
        libdebconfclient0 libapt-pkg7.0 sqv \
        # User management
        passwd login login.defs base-passwd \
        libpam-modules libpam-modules-bin libpam-runtime libpam0g \
        # Text processing tools
        perl-base mawk grep sed diffutils \
        # System utilities
        findutils hostname util-linux mount \
        sysvinit-utils init-system-helpers \
        # Terminal
        ncurses-bin ncurses-base libtinfo6 \
        # Archiving
        tar gzip \
        # Shells (keep dash for /bin/sh)
        bash \
        # Security/audit libs not needed for network-only app
        libaudit-common libaudit1 libseccomp2 \
        libselinux1 libsemanage-common libsemanage2 libsepol2 \
        libcap-ng0 libcap2 libacl1 libattr1 \
        # Block device / mount libs
        libblkid1 libmount1 libsmartcols1 \
        # Systemd libs
        liblastlog2-2 libsystemd0 libudev1 \
        # Misc
        bsdutils \
    2>/dev/null || true && \
    rm -rf /var/lib/apt /var/lib/dpkg /etc/apt /etc/dpkg \
           /usr/bin/apt* /usr/bin/dpkg* /usr/lib/apt /usr/lib/dpkg

# hadolint ignore=DL3045
COPY --chown=app:app --from=live_builder $BUNDLE_PATH $BUNDLE_PATH
# hadolint ignore=DL3045
COPY --chown=app:app . ./

USER app

ENTRYPOINT ["bundle", "exec", "ruby", "server.rb"]
