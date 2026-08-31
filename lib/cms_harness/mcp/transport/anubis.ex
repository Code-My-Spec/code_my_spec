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

  @client_info %{"name" => "cms-harness", "version" => "1"}

  # The *name*, not the pid `start_link/1` hands back — that is the client's
  # supervisor, and calling `list_tools` on it reaches `:supervisor.handle_call`
  # with an operation no supervisor has a clause for. Anubis says as much in its
  # own docs ("use the client by passing the registered name") and this ignored
  # it, which cost a second crash loop on top of the first.
  @impl true
  def connect(name, opts) do
    with {:ok, headers} <- headers(opts),
         {:ok, _supervisor} <- start_client(name, opts, headers) do
      {:ok, name}
    end
  end

  defp start_client(name, opts, headers) do
      Anubis.Client.start_link(
        name: name,
        transport_name: transport_name(name),
        transport: transport(opts, headers),
        client_info: @client_info,
        capabilities: %{},
        protocol_version: "2025-06-18"
      )
  end

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
  defp transport_name({:via, registry, key}), do: {:via, registry, {:transport, key}}
  defp transport_name({:global, term}), do: {:global, {:transport, term}}
  defp transport_name(name) when is_atom(name), do: Module.concat(name, Transport)
  defp transport_name(other), do: other

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
           }}
        end
    end
  end

  # A subprocess on this machine authenticates by being on this machine.
  defp stdio_needs_none(opts), do: if(Keyword.get(opts, :command), do: %{}, else: nil)

  @impl true
  def call(client, tool, arguments) do
    case Anubis.Client.call_tool(client, tool, arguments) do
      {:ok, %{is_error: true} = response} -> {:error, text(response)}
      {:ok, response} -> {:ok, text(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_tool_names(client) do
    case Anubis.Client.list_tools(client) do
      {:ok, %{result: %{"tools" => tools}}} -> {:ok, Enum.map(tools, & &1["name"])}
      {:ok, other} -> {:error, {:unexpected_tool_list, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Flattened to a string on purpose. The caller is an `Alloy.Tool`, and Alloy
  # hands a tool's result to the model as text — so a structured value here
  # would be inspected into one anyway, at a layer with no idea what it is
  # looking at.
  defp text(%{result: %{"content" => content}}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => t} -> t
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp text(%{result: result}), do: inspect(result)
  defp text(other), do: inspect(other)
end
