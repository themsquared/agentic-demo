# WeatherWise agent image — built once by setup.sh and loaded into k3d via
# `k3d image import` (no registry needed). AgentRegistry deploys this image onto
# the kagent runtime when the promotion Deployment is applied.
#
# Base image provides the kagent ADK runtime: its entrypoint is
#   kagent-adk run --host 0.0.0.0 --port 8080 <agent-name>
# which imports `<agent-name>.agent:root_agent`, serves it over A2A on :8080,
# and registers the agent with the kagent controller using the KAGENT_URL /
# KAGENT_NAME / KAGENT_NAMESPACE env vars that AgentRegistry injects at deploy.
ARG DOCKER_REGISTRY=ghcr.io
ARG VERSION=0.8.0-beta6
FROM $DOCKER_REGISTRY/kagent-dev/kagent/kagent-adk:$VERSION

WORKDIR /app

COPY weatherwise/ weatherwise/
COPY pyproject.toml pyproject.toml
COPY README.md README.md
COPY .python-version .python-version

RUN uv sync

ENV OTEL_SERVICE_NAME=weatherwise

# Arg appended to the base ENTRYPOINT → `kagent-adk run ... weatherwise`
CMD ["weatherwise"]
