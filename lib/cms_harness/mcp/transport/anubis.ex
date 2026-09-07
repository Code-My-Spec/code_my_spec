defmodule CmsHarness.Mcp.Transport.Anubis do
  @moduledoc """
  A real MCP session over streamable HTTP.

  Nothing here hand-rolls a protocol: `anubis_mcp` is already a dependency and
  its client does the handshake, holds the session id and correlates replies.
  What this adds is the shape the rest of the harness expects, and the choice of
  what a tool's answer looks like by the time an `Alloy.Tool` returns it.
  """

  @behaviour CmsHarness.Mcp.Transport

  alias CmsHarness.Token

  @client_name "cms-harness"

  # What our own server speaks. Overridable per session because a third-party
  # server speaks whatever it speaks, and one of them answers an unsupported
  # proposal with silence rather than with a version it does support — see
  # `CmsHarness.Browser`.
  @protocol_version "2025-06-18"

  # The *name*, not the pid `start_link/1` hands back — that is the client's
  # supervisor, and calling `list_tools` on it reaches `:supervisor.handle_call`
  # with an operation no supervisor has a clause for. Anubis says as much in its
  # own docs ("use the client by passing the registered name") and this ignored
  # it, which cost a second crash loop on top of the first.
  @impl true
  def connect(name, opts) do
    with {:ok, headers} <- headers(opts),
         {:ok, supervisor} <- start_client(name, opts, headers) do
      # Unlinked, deliberately. `Anubis.Client.start_link/1` links its
      # supervisor to whoever called it, and callers here are processes that
      # must outlive a session: an agent whose browser died is an agent that
      # cannot browse, not one that should stop. Twice tonight a link like this
      # took down something far more important than the session at the end of
      # it.
      Process.unlink(supervisor)
      ready(name)
    end
  end

  # Started is not the same as handshaken, and only this transport has a
  # handshake — which is why waiting for one belongs here rather than in a
  # caller that also has to work against a session with no wire at all.
  #
  # `start_link/1` returns once the process is up, with the MCP `initialize`
  # round trip still in flight behind it, so a `tools/list` sent straight after
  # is answered "Server capabilities not set". That reads as a broken server
  # rather than as a question asked too early, and it is why every agent on this
  # machine was recorded with no browser tools while vibium sat installed on it.
  #
  # Waited for with `tools/list` rather than with `ping`, because a ping is not
  # a thing every server implements: vibium answers `initialize` and
  # `tools/list` and errors on `ping`, so pinging for readiness declared a
  # perfectly healthy server unreachable. The first request the caller was going
  # to make anyway is the honest thing to wait on.
  defp ready(name, attempts \\ 20) do
    case Anubis.Client.list_tools(name) do
      {:ok, _tools} ->
        {:ok, name}

      {:error, _reason} when attempts > 1 ->
        Process.sleep(100)
        ready(name, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_client(name, opts, headers) do
    Anubis.Client.start_link(
      name: name,
      transport_name: transport_name(name),
      transport: transport(opts, headers),
      client_info: client_info(name),
      capabilities: %{},
      protocol_version: Keyword.get(opts, :protocol_version, @protocol_version)
    )
  end

  # One `client_info["name"]` per session, because Anubis keys an ETS table on
  # it — `anubis_client_<name>_tool_validators`, created `:private` by whichever
  # client gets there first (`Anubis.Client.Cache.ensure_table/1`).
  #
  # A constant here meant every session in this VM computed the same table name,
  # so exactly one could ever work. The browser starts at boot and took it;
  # every agent after that died on
  #
  #     :ets.internal_delete_all(:"anubis_client_cms-harness_tool_validators", :undefined)
  #     ** (ArgumentError) the table identifier refers to an ETS table with
  #        insufficient access rights
  #
  # which surfaced as `:start_timed_out` — the agent's session never came up,
  # and thirteen restore attempts in a row failed without one succeeding.
  #
  # The cost is an atom per distinct session, since Anubis interns the derived
  # table name. That is the trade the library forces and it is a bounded one: an
  # atom per agent start against a table of a million, where the alternative is
  # one working session per machine.
  @doc false
  @spec client_info(term()) :: map()
  def client_info(name),
    do: %{"name" => @client_name <> "-" <> session_tag(name), "version" => "1"}

  # Readable in a log line and unique per session. The agent id already is both,
  # and the browser's global name stands in for the one session that has no
  # agent behind it.
  defp session_tag({:via, Registry, {_registry, {:mcp, agent_id, _base_url}}}), do: agent_id
  defp session_tag({:global, term}) when is_atom(term), do: to_string(term)

  # The browser's own name is `{:global, {CmsHarness.Browser, :session}}`, so
  # the term inside is a tuple and `to_string/1` on it raises — which it did,
  # on every machine, for the one session that matters most. Hashed rather than
  # inspected because this ends up in an atom Anubis interns: `inspect/1` on a
  # tuple is long and full of characters, and the hash is stable for the same
  # name, which is all this needs to be.
  defp session_tag(other), do: other |> :erlang.phash2() |> Integer.to_string()

  # A client started under a via or global name has to say what to call its
  # transport: Anubis derives one from an atom name and raises on anything else.
  #
  # Neither of our names is an atom, and both are that way on purpose — an agent
  # id and a base url arrive as input, and `String.to_atom/1` on input grows the
  # atom table until the VM stops. So the sibling is derived here instead.
  #
  # Not doing this took the whole harness down: the client raised on start, the
  # channel join raised with it, and it retried every eighty milliseconds. The
  # stop hook read it correctly — the server was answering and this machine
  # could not hold a socket to it.
  #
  # The tag goes around the *key*, inside the pair. A `Registry` via tuple
  # carries `{registry_name, key}` as its third element, and wrapping that whole
  # pair names a registry called `:transport` that nobody started — which is
  # what the first version of this did, and it stopped every agent on every
  # machine from starting for forty minutes.
  #
  # Public because getting it wrong is silent. A malformed via tuple is a
  # perfectly good term; nothing objects until a supervisor start deep inside
  # Anubis does, and its `ArgumentError: unknown registry: :transport` reaches a
  # person as "the agent was not started on its machine", which reads like the
  # machine's fault. So it is tested directly.
  @doc false
  @spec transport_name(term()) :: term()
  def transport_name({:via, Registry, {registry, key}}),
    do: {:via, Registry, {registry, {:transport, key}}}

  def transport_name({:global, term}), do: {:global, {:transport, term}}
  def transport_name(name) when is_atom(name), do: Module.concat(name, Transport)
  def transport_name(other), do: other

  # Two shapes, because the servers this harness talks to come in two.
  #
  # Ours is HTTP and authenticated: the route the proxy already proved. A
  # third-party one on this machine is a subprocess speaking JSON-RPC over its
  # own stdin and stdout — `vibium mcp` is exactly that — and has no URL and no
  # credential, because it is not reached across anything.
  defp transport(opts, headers) do
    case Keyword.get(opts, :command) do
      nil ->
        {:streamable_http,
         base_url: Keyword.fetch!(opts, :base_url),
         mcp_path: Keyword.fetch!(opts, :mcp_path),
         headers: headers}

      command ->
        {:stdio, command: command, args: Keyword.get(opts, :args, [])}
    end
  end

  # The credential is fetched here rather than by the caller, because whether
  # one is needed is a fact about the wire. Lifted from `McpController`, which
  # has always sent exactly these two: a bearer token for this checkout, and the
  # harness id, which names the working copy *and* the project it belongs to and
  # so cannot contradict itself.
  defp headers(opts) do
    case Keyword.get(opts, :headers) || stdio_needs_none(opts) do
      %{} = given ->
        {:ok, given}

      nil ->
        with {:ok, token} <- Token.access_token(Keyword.get(opts, :root)) do
          {:ok,
           %{
             "authorization" => "Bearer " <> token,
             "x-harness-id" => Keyword.get(opts, :working_copy_id)
           }
           |> put_agent(Keyword.get(opts, :agent_id))}
        end
    end
  end

  # Which agent is calling, when one is.
  #
  # The connection is the only place this can live. An agent inside our own BEAM
  # still reaches the server over HTTP — `Config.server_url()` is a real URL, on
  # Fly in production — so nothing about the caller is ambient, and identity
  # travels the way the working copy's already does.
  #
  # The value is the server's own: it mints the agent row, sends the id over the
  # channel to start it, and the harness hands it back here. So this is not a
  # claim the harness invents, and the server can check the agent belongs to a
  # working copy this caller holds.
  #
  # Absent for a connection that is not an agent's — the CLI's, a subprocess's —
  # and absent is the right answer there rather than a placeholder, because a
  # tool that needs an agent should refuse rather than act on a guess.
  defp put_agent(headers, agent_id) when is_binary(agent_id) and agent_id != "",
    do: Map.put(headers, "x-agent-id", agent_id)

  defp put_agent(headers, _agent_id), do: headers

  # A subprocess on this machine authenticates by being on this machine.
  defp stdio_needs_none(opts), do: if(Keyword.get(opts, :command), do: %{}, else: nil)

  @impl true
  def call(client, tool, arguments), do: call(client, tool, arguments, [])

  @impl true
  def call(client, tool, arguments, opts) do
    case Anubis.Client.call_tool(client, tool, arguments, opts) do
      {:ok, %{is_error: true} = response} -> {:error, text(response)}
      {:ok, response} -> {:ok, text(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_tool_names(client) do
    with {:ok, tools} <- list_tools(client), do: {:ok, Enum.map(tools, & &1["name"])}
  end

  @impl true
  def list_tools(client) do
    case Anubis.Client.list_tools(client) do
      {:ok, %{result: %{"tools" => tools}}} -> {:ok, tools}
      {:ok, other} -> {:error, {:unexpected_tool_list, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Flattened to a string on purpose. The caller is an `Alloy.Tool`, and Alloy
  # hands a tool's result to the model as text — so a structured value here
  # would be inspected into one anyway, at a layer with no idea what it is
  # looking at.
  defp text(%{result: %{"content" => content}}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp text(%{result: result}), do: inspect(result)
  defp text(other), do: inspect(other)
end
