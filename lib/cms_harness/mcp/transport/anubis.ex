defmodule CmsHarness.Mcp.Transport.Anubis do
  @moduledoc """
  A real MCP session: over streamable HTTP with `Mcp.Http`, over stdio with
  `anubis_mcp`'s client.

  What this adds is the shape the rest of the harness expects, and the choice of
  what a tool's answer looks like by the time an `Alloy.Tool` returns it.
  """

  require Logger

  @behaviour CmsHarness.Mcp.Transport

  alias CmsHarness.Mcp.Http
  alias CmsHarness.Token

  @client_name "cms-harness"

  # What our own server speaks; overridable per session (see `CmsHarness.Browser`).
  @protocol_version "2025-06-18"

  # Answers the client's *name*: the pid `start_link/1` returns is its
  # supervisor, which cannot handle client calls.
  @impl true
  def connect(name, opts) do
    case Keyword.get(opts, :command) do
      nil -> connect_http(opts)
      _command -> connect_client(name, opts)
    end
  end

  # Over HTTP a call is one request in the caller's process (`Mcp.Http`), so a
  # slow call fails alone instead of taking the client, and the agent, with it.
  defp connect_http(opts) do
    with {:ok, headers} <- headers(opts) do
      opts
      |> Keyword.fetch!(:base_url)
      |> Kernel.<>(Keyword.fetch!(opts, :mcp_path))
      |> Http.open(headers, Keyword.get(opts, :protocol_version, @protocol_version),
        headers_provider: fn -> headers(opts) end
      )
    end
  end

  defp connect_client(name, opts) do
    with {:ok, headers} <- headers(opts),
         {:ok, supervisor} <- start_client(name, opts, headers) do
      # Unlinked: callers must outlive a session (an agent whose browser died
      # should not stop).
      Process.unlink(supervisor)
      ready(name)
    end
  end

  # Started is not handshaken: a request before `initialize` completes is
  # answered "Server capabilities not set". Waits with `tools/list`, not `ping`,
  # which not every server implements (vibium does not).
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
    case client_link(name, opts, headers) do
      {:error, {:already_started, pid}} ->
        replace_leaked(pid, name, opts, headers)

      # The shape it actually arrives in: the collision is on the supervisor's
      # child, so the tuple comes back wrapped.
      {:error, {:shutdown, {:failed_to_start_child, _child, {:already_started, pid}}}} ->
        replace_leaked(pid, name, opts, headers)

      result ->
        result
    end
  end

  # A client left behind by a gone session (the unlink's cost) still holds the
  # name. Replaced, never reused: it carries the old session's transport and
  # headers. See knowledge/harness, "MCP transport".
  defp replace_leaked(pid, name, opts, headers) do
    Logger.info("[CmsHarness] replacing a leaked MCP client for #{inspect(name)}")

    stop_leaked(pid)
    await_released(name)
    client_link(name, opts, headers)
  end

  @impl true
  def disconnect(%Http{} = client), do: Http.close(client)

  def disconnect(name) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) -> stop_leaked(pid)
      _ -> :ok
    end

    :ok
  end

  @doc """
  Take down the process tree holding a leaked client's name.

  `{:already_started, pid}` names the client, whose `:one_for_all` supervisor
  would restart it under the same name; so the supervisor is stopped. It is
  anonymous (our names are `:via` tuples) and found through the child.

  Public so it can be tested against a supervisor of the same shape.
  """
  @spec stop_leaked(pid()) :: :ok
  def stop_leaked(pid) do
    pid
    |> owner()
    |> stop_client()
  end

  # The supervisor holding this client, or the client itself when nothing
  # supervises it.
  #
  # `:parent` is the spawner, which is not always a supervisor; it must prove
  # it is one (`:proc_lib.initial_call/1`), or the caller would be killed.
  defp owner(pid), do: pid |> Process.info(:parent) |> supervisor_of(pid)

  defp supervisor_of({:parent, parent}, pid) when is_pid(parent) do
    parent |> :proc_lib.initial_call() |> holder(parent, pid)
  end

  defp supervisor_of(_info, pid), do: pid

  defp holder({:supervisor, _module, _args}, parent, _pid), do: parent
  defp holder(_initial_call, _parent, pid), do: pid

  # `:normal` first, so children stop in order; brutal kill only if refused.
  defp stop_client(pid) do
    Supervisor.stop(pid, :normal, 5_000)
  catch
    :exit, _ ->
      Process.exit(pid, :kill)
      :ok
  end

  # The `Registry` drops the name one message after the exit. Waits on the
  # condition; if still held, the link fails loudly as before.
  defp await_released(name, attempts \\ 50)

  defp await_released(_name, 0), do: :ok

  defp await_released(name, attempts) do
    case GenServer.whereis(name) do
      nil ->
        :ok

      _pid ->
        Process.sleep(10)
        await_released(name, attempts - 1)
    end
  end

  defp client_link(name, opts, headers) do
    Anubis.Client.start_link(
      name: name,
      transport_name: transport_name(name),
      transport: transport(opts, headers),
      client_info: client_info(name),
      capabilities: %{},
      protocol_version: Keyword.get(opts, :protocol_version, @protocol_version)
    )
  end

  # Unique per session: Anubis keys a `:private` ETS table on the name, so a
  # shared name lets only one session work. Costs an atom per session.
  @doc "Public so the session-tagged client name/version can be asserted directly."
  @spec client_info(term()) :: map()
  def client_info(name),
    do: %{"name" => @client_name <> "-" <> session_tag(name), "version" => "1"}

  # The agent id, or a hash of a browser session's root (it becomes an atom).
  defp session_tag({:via, Registry, {_registry, {:mcp, agent_id, _base_url}}}), do: agent_id

  defp session_tag({:via, Registry, {_registry, {:browser, root}}}),
    do: "browser-" <> Integer.to_string(:erlang.phash2(root))

  defp session_tag({:global, term}) when is_atom(term), do: to_string(term)

  # Anything else: hashed; stable for the same name.
  defp session_tag(other), do: other |> :erlang.phash2() |> Integer.to_string()

  # Anubis derives a transport name only from an atom, and our names are not
  # atoms (never `String.to_atom/1` on input). The tag wraps the Registry *key*,
  # not the `{registry, key}` pair, which would name a registry nobody started.
  @doc "Public so the registry-name wrapping can be asserted directly rather than found later as an Anubis crash."
  @spec transport_name(term()) :: term()
  def transport_name({:via, Registry, {registry, key}}),
    do: {:via, Registry, {registry, {:transport, key}}}

  def transport_name({:global, term}), do: {:global, {:transport, term}}
  def transport_name(name) when is_atom(name), do: Module.concat(name, Transport)
  def transport_name(other), do: other

  # Only stdio subprocesses (`vibium mcp`) use Anubis; ours is HTTP.
  defp transport(opts, _headers) do
    {:stdio, command: Keyword.fetch!(opts, :command), args: Keyword.get(opts, :args, [])}
  end

  # Fetched here: whether a credential is needed is a fact about the wire. The
  # same two headers `McpController` sends: a bearer token and the harness id.
  defp headers(opts) do
    case Keyword.get(opts, :headers) || stdio_needs_none(opts) do
      %{} = given ->
        {:ok, given}

      nil ->
        with {:ok, token} <- Token.access_token(Keyword.get(opts, :root)) do
          {:ok,
           %{
             "authorization" => "Bearer " <> token,
             "x-harness-id" => Keyword.get(opts, :working_copy_id),
             "x-project-id" => Keyword.get(opts, :project_id)
           }
           |> put_agent(Keyword.get(opts, :agent_id))
           |> Map.reject(fn {_key, value} -> is_nil(value) end)}
        end
    end
  end

  # Which agent is calling, as an `x-agent-id` header: the server minted the id
  # and can check it belongs to this copy. Absent, never a placeholder, for a
  # non-agent connection.
  defp put_agent(headers, agent_id) when is_binary(agent_id) and agent_id != "",
    do: Map.put(headers, "x-agent-id", agent_id)

  defp put_agent(headers, _agent_id), do: headers

  # A subprocess on this machine authenticates by being on this machine.
  defp stdio_needs_none(opts), do: if(Keyword.get(opts, :command), do: %{}, else: nil)

  @impl true
  def call(client, tool, arguments), do: call(client, tool, arguments, [])

  @impl true
  def call(%Http{} = client, tool, arguments, opts) do
    case Http.call_tool(client, tool, arguments, opts) do
      {:ok, %{"isError" => true} = result} -> {:error, text(%{result: result})}
      {:ok, result} -> {:ok, text(%{result: result})}
      {:error, reason} -> {:error, reason}
    end
  end

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
  def list_tools(%Http{} = client), do: Http.list_tools(client)

  def list_tools(client) do
    case Anubis.Client.list_tools(client) do
      {:ok, %{result: %{"tools" => tools}}} -> {:ok, tools}
      {:ok, other} -> {:error, {:unexpected_tool_list, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Flattened to text: Alloy hands a tool result to the model as text anyway.
  defp text(%{result: %{"content" => content}}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp text(%{result: result}), do: inspect(result)
  defp text(other), do: inspect(other)
end
