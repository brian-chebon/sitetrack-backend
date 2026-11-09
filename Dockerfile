# Compile the API to a native executable, then ship it on an empty image with
# only the runtime libraries Dart needs (the official dart image's pattern).
FROM dart:3.13.7 AS build
WORKDIR /app

# Dependencies first, so editing source does not re-download them.
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY bin bin
COPY lib lib
RUN dart pub get --offline \
 && dart compile exe bin/server.dart -o /app/server \
 && dart compile exe bin/seed.dart -o /app/seed


# `docker compose run --rm test` runs the test suite against the db service;
# `docker compose run --rm test dart run tool/bench.dart` times the screens.
FROM build AS test
COPY migrations migrations
COPY docs docs
COPY test test
COPY tool tool
CMD ["dart", "test"]


FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/server /app/server
COPY --from=build /app/seed /app/seed
COPY migrations /app/migrations
COPY docs/openapi.yaml /app/docs/openapi.yaml

WORKDIR /app
ENV PORT=8080 \
    MIGRATIONS_DIR=/app/migrations \
    OPENAPI_PATH=/app/docs/openapi.yaml
EXPOSE 8080
# nobody:nogroup; the API needs no privileges.
USER 65534:65534
CMD ["/app/server"]
