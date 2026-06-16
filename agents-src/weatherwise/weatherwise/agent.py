"""WeatherWise — a packaged, tool-using agent shipped through AgentRegistry.

This is a BYO-image agent (it ships as a container), in contrast to the
declarative system-prompt agents under manifests/kagent/agents/. AgentRegistry
deploys this image onto the kagent runtime when you apply the promotion
Deployment (see manifests/agentregistry/deployments.yaml).

Two design choices keep it consistent with the rest of the demo:

  1. The LLM is reached through the AgentGateway, not Anthropic directly. We use
     google-adk's LiteLlm with the `openai/` prefix so it speaks the gateway's
     OpenAI-compatible LLM API. The gateway injects the real Anthropic key and
     pins the upstream model, so the api_key here is a placeholder and the model
     string only needs the `openai/` prefix to select LiteLLM's OpenAI client.

  2. Its tools are MCP tools resolved at deploy time. AgentRegistry reads the
     catalog Agent's `mcpServers` refs, resolves them to URLs, and injects
     MCP_SERVERS_CONFIG into the container — get_mcp_tools() reads that env.
     For this demo that ref is `weather-mcp`, which resolves to the gateway's
     /mcp/weather endpoint. So both LLM and tool traffic flow through the gateway.
"""

import os

from google.adk import Agent
from google.adk.models.lite_llm import LiteLlm

from .mcp_tools import get_mcp_tools
from .prompts_loader import build_instruction

# OpenTelemetry — emit spans to the collector the registry/kagent wires in.
os.environ.setdefault("OTEL_SERVICE_NAME", "weatherwise")
from google.adk.telemetry.setup import maybe_set_otel_providers  # noqa: E402

maybe_set_otel_providers()


def create_model() -> LiteLlm:
    """Claude, reached through the AgentGateway's OpenAI-compatible endpoint.

    Override the gateway URL with LLM_GATEWAY_BASE_URL if the namespaces change.
    """
    base_url = os.environ.get(
        "LLM_GATEWAY_BASE_URL",
        "http://agentgateway-proxy.agentgateway-system.svc.cluster.local/anthropic/v1",
    )
    # The gateway pins the upstream model and injects the provider key; the
    # `openai/` prefix selects LiteLLM's OpenAI-compatible client and the
    # api_key is a non-secret placeholder (the gateway supplies the real one).
    return LiteLlm(
        model="openai/claude-sonnet-4-6",
        api_base=base_url,
        api_key="sk-gateway-injected",
    )


_DEFAULT_INSTRUCTION = """\
You are WeatherWise, a concise weather concierge.

When the user asks about weather for a place, call the weather tool to get live
conditions, then answer in one or two sentences with the temperature and a short
description. If the user asks something unrelated to weather, answer briefly and
offer to check the weather for a location.
"""

mcp_tools = get_mcp_tools()
root_agent = Agent(
    model=create_model(),
    name="weatherwise",
    description="Weather concierge — live conditions for any city, shipped via AgentRegistry.",
    instruction=build_instruction(_DEFAULT_INSTRUCTION),
    tools=mcp_tools if mcp_tools else [],
)
