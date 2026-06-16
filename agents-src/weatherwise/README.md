# WeatherWise — a packaged agent shipped through AgentRegistry

A **BYO-image** agent (it ships as a container), in contrast to the declarative
system-prompt agents under [`../../manifests/kagent/agents/`](../../manifests/kagent/agents/).
It exists to demonstrate the AgentRegistry → kagent **promotion** lifecycle: a
catalog `Agent` with a `source.image`, deployed onto the `kagent` runtime by an
AgentRegistry `Deployment`, which AgentRegistry materializes as a running
`kagent.dev/Agent` CRD.

- **LLM** → Claude via the AgentGateway (`google-adk` LiteLlm, `openai/` prefix
  against the gateway's OpenAI-compatible `/anthropic` endpoint). The gateway
  injects the key and pins the model.
- **Tools** → MCP tools resolved at deploy time from the catalog Agent's
  `mcpServers` refs (injected as `MCP_SERVERS_CONFIG`). Here that's `weather-mcp`
  → the gateway's `/mcp/weather`. So LLM **and** tool traffic both flow through
  the gateway.

## Build (what `setup.sh` does once)

```bash
docker build -t solo-demo/weatherwise:latest agents-src/weatherwise
k3d image import solo-demo/weatherwise:latest -c ai-demo
```

`k3d image import` loads the image straight into the cluster's containerd — no
registry required. The catalog Agent references `solo-demo/weatherwise:latest`
with an `IfNotPresent` pull policy so kagent uses the imported image.

## Promote (what the kagent demo does live)

```bash
# register the catalog Agent (carries source.image) + MCP ref, then deploy it
arctl apply -f manifests/agentregistry/weatherwise-agent.yaml
arctl apply -f manifests/agentregistry/deployments.yaml   # targetRef→runtimeRef(kagent)
```

AgentRegistry's Kagent adapter translates the Deployment into a `kagent.dev/Agent`
running this image in the `kagent` namespace.

## Local iteration (optional)

```bash
arctl run        # runs the agent + a local MCP via docker-compose
```
