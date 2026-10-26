# python:3.13-slim pinned by index digest (multi-arch). The digest is fixed here; only the registry that serves it
# varies (ECR Public by default, Docker Hub as a fallback, same digest), so a mirror cannot change the content.
ARG PYTHON_IMAGE=public.ecr.aws/docker/library/python
FROM ${PYTHON_IMAGE}:3.13-slim@sha256:d98cc29d3266e535dd9da1099688d9cb3ca4753813571e071763d17725460962 AS test
WORKDIR /app
COPY src ./src
COPY tests ./tests
RUN python -m unittest discover -s tests

FROM ${PYTHON_IMAGE}:3.13-slim@sha256:d98cc29d3266e535dd9da1099688d9cb3ca4753813571e071763d17725460962 AS runtime
ARG GIT_SHA=local
LABEL org.opencontainers.image.revision=${GIT_SHA} \
      org.opencontainers.image.source=https://github.com/trungleviet-agilityio/ship-it-safely
ENV GIT_SHA=${GIT_SHA} \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
# The app is stdlib only: remove pip and setuptools (and the libraries they vendor) from the runtime image.
RUN python -m pip uninstall --yes pip setuptools wheel
WORKDIR /app
# Copy from the test stage so the final image is only built if tests passed.
COPY --from=test --chown=app:app /app/src ./src
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).status == 200 else 1)"]
CMD ["python", "src/board.py"]
