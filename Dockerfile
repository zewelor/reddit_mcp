FROM ruby:4.0.0-slim AS base

RUN groupadd -g 1000 app && \
    useradd -u 1000 -g app -d /app -s /bin/bash app

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

# Remove unnecessary packages and files to minimize image size (~30MB savings)
# Keep only what Ruby needs: libc6, libssl3t64, libgmp10, zlib1g, ca-certificates, libyaml, libffi
# hadolint ignore=DL3027
RUN dpkg --purge --force-remove-essential --force-depends \
        passwd \
        perl-base \
        findutils \
        diffutils \
        ncurses-bin \
        ncurses-base \
        debconf \
        mawk \
        hostname \
        login \
        util-linux \
        mount \
        sysvinit-utils \
        init-system-helpers \
    2>/dev/null || true && \
    rm -rf /var/lib/apt/lists/* /var/lib/dpkg/info/* /var/cache/* /var/log/* \
           /usr/share/doc /usr/share/man /usr/share/info /usr/share/lintian /tmp/*

# hadolint ignore=DL3045
COPY --chown=app:app --from=live_builder $BUNDLE_PATH $BUNDLE_PATH
# hadolint ignore=DL3045
COPY --chown=app:app . ./

USER app

ENTRYPOINT ["bundle", "exec", "ruby", "server.rb"]
