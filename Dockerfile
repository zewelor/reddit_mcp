FROM ruby:4.0.0-alpine AS base

# Alpine uses addgroup/adduser instead of groupadd/useradd
RUN addgroup -g 1000 app && \
    adduser -u 1000 -G app -D -H -h /app -s /sbin/nologin app

WORKDIR /app

# We mount whole . dir into app, so vendor/bundle would get overwritten
ENV BUNDLE_PATH=/bundle \
    BUNDLE_BIN=/bundle/bin \
    GEM_HOME=/bundle

ENV PATH="${BUNDLE_BIN}:${PATH}"

FROM base AS basedev

# build-base is Alpine's equivalent to build-essential
ARG DEV_PACKAGES="build-base"

ENV BUNDLE_AUTO_INSTALL=true

# hadolint ignore=SC2086
RUN apk add --no-cache $DEV_PACKAGES

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

# Alpine is already minimal - just clean up cache and temp files
# No complex dpkg --purge needed - these packages simply aren't installed
RUN rm -rf /var/cache/apk/* /tmp/* /root/.cache /root/.bundle \
           /usr/share/doc /usr/share/man

# hadolint ignore=DL3045
COPY --chown=app:app --from=live_builder $BUNDLE_PATH $BUNDLE_PATH
# hadolint ignore=DL3045
COPY --chown=app:app . ./

USER app

ENTRYPOINT ["bundle", "exec", "ruby", "server.rb"]
