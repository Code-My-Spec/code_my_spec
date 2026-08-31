defmodule CmsHarness.Mcp do
  @moduledoc """
  An MCP session this machine holds itself.

  The harness has spoken MCP for a long time and never as a participant.
  `CmsHarness.Web.McpController` is a pipe: it forwards bytes with
  `decode_body: false`, and `mcp-session-id` is in both its forwarded and
  returned header lists — it passes the id through in either direction and
  never mints one. The session it carries belongs to Claude Code, which sent
  the `initialize` and holds the id. That is right for a proxy and useless to
  an agent running inside this BEAM, which has no Claude Code in front of it.

  So this is the missing half, and only that half. The route was already
  proven by the proxy and is lifted from it verbatim: `server_url <>
  "/mcp/harness"`, a bearer token from `Token.access_token/1`, and the harness
  id in a header. What is added is a session — `initialize`, keep the id,
  `notifications/initialized`, then `tools/call` — and `Anubis.Client` with its
  streamable-HTTP transport already does all of it.

  ## Why a client and not one more REST endpoint

  Reaching our own server is the smaller half of what this is for. A QA agent
  also carries a browser, and a browser is an MCP server with eighty-five tools
  on it. One client reaches both; an endpoint of ours reaches one of them.

  ## One session per agent, not per call

  `initialize` is a round trip, and paying it on every `run_script` would put
  the latency back that running the script beside the data took out. The
  session lives as long as the agent does and is named after it, so two agents
  on one machine cannot read each other's.
  """

  require Logger

  alias CmsHarness.Config
  alias CmsHarness.Mcp.Transport

  @doc """
  Start a session against this project's own server, for one agent.

  `{:error, :no_credential}` when the machine has nothing to authenticate with,
  which is the same refusal every other server call here gives and means the
  same thing.
  """
  @spec connect(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, term()} | {:error, term()}
  def connect(agent_id, working_copy_id, root) do
    # The credential is not fetched here. Which one is needed — or whether one
    # is needed at all — is the transport's question: the real one authenticates
    # over HTTP, and the local one is already inside the server. Asking for a
    # token here made an agent unable to hold a session in any environment
    # without a machine credential, including every test.
    Transport.impl().connect(name(agent_id, Config.server_url()),
      base_url: Config.server_url(),
      mcp_path: "/mcp/harness",
      working_copy_id: working_copy_id,
      root: root
    )
  end

  @doc """
  Start a session against any MCP server, which is how a third-party one — a
  browser, say — arrives as a tool rather than as its list.
  """
  @spec start(String.t(), String.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def start(agent_id, base_url, path, headers) do
    Transport.impl().connect(name(agent_id, base_url),
      base_url: base_url,
      mcp_path: path,
      headers: headers
    )
  end

  @doc """
  Call a tool and hand back its text.

  Flattened to a string on purpose. The caller is an `Alloy.Tool`, and Alloy
  hands a tool's result to the model as text — so a structured value here would
  be inspected into one anyway, at a layer with no idea what it is looking at.
  """
  @spec call(term(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def call(client, tool, arguments), do: Transport.impl().call(client, tool, arguments)

  @doc "The names a server offers, without their schemas. See `Tools.Gateway`."
  @spec list_tool_names(term()) :: {:ok, [String.t()]} | {:error, term()}
  def list_tool_names(client), do: Transport.impl().list_tool_names(client)

  @doc "The session for this agent against this server, or nil."
  @spec whereis(String.t(), String.t()) :: pid() | nil
  def whereis(agent_id, base_url), do: GenServer.whereis(name(agent_id, base_url))

  # Named after the agent and the server, so two agents on one machine hold two
  # sessions and neither can read the other's. `:via` rather than an atom
  # because agent ids arrive from the server and `String.to_atom/1` on an input
  # grows the atom table until the VM stops.
  defp name(agent_id, base_url) do
    {:via, Registry, {CmsHarness.Registry, {:mcp, agent_id, base_url}}}
  end

end
