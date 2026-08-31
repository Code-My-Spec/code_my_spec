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

  @impl true
  def connect(name, opts) do
    with {:ok, headers} <- headers(opts) do
      Anubis.Client.start_link(
        name: name,
        transport:
          {:streamable_http,
           base_url: Keyword.fetch!(opts, :base_url),
           mcp_path: Keyword.fetch!(opts, :mcp_path),
           headers: headers},
        client_info: @client_info,
        capabilities: %{},
        protocol_version: "2025-06-18"
      )
    end
  end

  # The credential is fetched here rather than by the caller, because whether
  # one is needed is a fact about the wire. Lifted from `McpController`, which
  # has always sent exactly these two: a bearer token for this checkout, and the
  # harness id, which names the working copy *and* the project it belongs to and
  # so cannot contradict itself.
  defp headers(opts) do
    case Keyword.get(opts, :headers) do
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
