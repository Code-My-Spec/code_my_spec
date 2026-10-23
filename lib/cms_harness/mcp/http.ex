defmodule CmsHarness.Mcp.Http do
  @moduledoc """
  An MCP session over streamable HTTP, one plain request per call.

  `Anubis.Client` sends every request from one process, synchronously, so an
  agent's parallel tool calls queued behind one another, and a call that waited
  past its deadline exited inside the client. The session watcher saw the
  client die and took the agent's engine and its turn down with it. Main
  restarted four times in three minutes on a batch of two `run_script`s and a
  `check_answer` (2026-10-12). Here each call is its own request, made in the
  caller's process: a slow one times out alone, as an error the model reads.

  The server still answers one request per session at a time, so the default
  deadline also covers waiting behind a sibling call.

  The session id is the only state. It lives in a small `Agent`, linked to
  whoever opened the session, so a call made after the server forgot the
  session (`404`, as after a restart of the server) can initialize again
  without restarting the agent.
  """

  defstruct [:url, :headers, :protocol_version, :session, :headers_provider]

  @type t :: %__MODULE__{}

  @timeout :timer.minutes(2)
  @handshake_timeout 15_000

  @doc "Initialize a session against `url`."
  @spec open(String.t(), map(), String.t()) :: {:ok, t()} | {:error, term()}
  def open(url, headers, protocol_version, opts \\ []) do
    {:ok, session} = Agent.start_link(fn -> nil end)

    client = %__MODULE__{
      url: url,
      headers: headers,
      protocol_version: protocol_version,
      session: session,
      headers_provider: Keyword.get(opts, :headers_provider)
    }

    case initialize(client) do
      {:ok, id} ->
        Agent.update(session, fn _ -> id end)
        {:ok, client}

      {:error, _} = error ->
        Agent.stop(session)
        error
    end
  end

  @doc "End the session, on the server and here."
  @spec close(t()) :: :ok
  def close(%__MODULE__{session: session} = client) do
    if Process.alive?(session) do
      with id when is_binary(id) <- Agent.get(session, & &1),
           {:ok, client} <- refresh_headers(client) do
        Req.delete(req_options(client, @handshake_timeout, id))
      end

      Agent.stop(session)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Call a tool. `{:ok, result}` with the tool's own result map, error or not."
  @spec call_tool(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call_tool(client, tool, arguments, opts \\ []) do
    request(client, "tools/call", %{name: tool, arguments: arguments}, timeout(opts))
  end

  @doc "The tools the server offers, with their schemas."
  @spec list_tools(t()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(client) do
    case request(client, "tools/list", %{}, @handshake_timeout) do
      {:ok, %{"tools" => tools}} -> {:ok, tools}
      {:ok, other} -> {:error, {:unexpected_tool_list, other}}
      error -> error
    end
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout) || @timeout

  defp request(client, method, params, timeout, retried? \\ false) do
    id = Integer.to_string(System.unique_integer([:positive]))
    session = Agent.get(client.session, & &1)
    body = %{jsonrpc: "2.0", id: id, method: method, params: params}

    case post(client, body, timeout, session) do
      {:ok, %{status: 200} = response} ->
        reply(response, id)

      {:ok, %{status: 404}} when not retried? ->
        retry_with_fresh_session(client, method, params, timeout)

      {:ok, %{status: status, body: body}} ->
        {:error, "the server answered #{status}: #{String.slice(to_string(body), 0, 500)}"}

      {:error, _} = error ->
        error
    end
  end

  defp retry_with_fresh_session(client, method, params, timeout) do
    with {:ok, fresh} <- initialize(client) do
      Agent.update(client.session, fn _ -> fresh end)
      request(client, method, params, timeout, true)
    end
  end

  defp initialize(client) do
    body = %{
      jsonrpc: "2.0",
      id: "initialize",
      method: "initialize",
      params: %{
        protocolVersion: client.protocol_version,
        capabilities: %{},
        clientInfo: %{name: "cms-harness", version: "1"}
      }
    }

    with {:ok, %{status: 200} = response} <- post(client, body, @handshake_timeout, nil),
         {:ok, _result} <- reply(response, "initialize"),
         [id | _] <- Req.Response.get_header(response, "mcp-session-id"),
         {:ok, %{status: status}} when status in 200..299 <-
           post(
             client,
             %{jsonrpc: "2.0", method: "notifications/initialized"},
             @handshake_timeout,
             id
           ) do
      {:ok, id}
    else
      {:ok, %{status: status, body: body}} ->
        {:error, "initialize answered #{status}: #{String.slice(to_string(body), 0, 500)}"}

      [] ->
        {:error, "initialize answered without a session id"}

      {:error, _} = error ->
        error
    end
  end

  defp post(client, body, timeout, session) do
    with {:ok, client} <- refresh_headers(client) do
      client
      |> req_options(timeout, session)
      |> Keyword.put(:body, Jason.encode!(body))
      |> Req.post()
    end
  end

  # Long-lived agents must use the credential store's current token, not the
  # token that happened to be valid when their MCP session was opened.
  defp refresh_headers(%{headers_provider: nil} = client), do: {:ok, client}

  defp refresh_headers(client) do
    with {:ok, headers} <- client.headers_provider.(), do: {:ok, %{client | headers: headers}}
  end

  defp req_options(client, timeout, session) do
    headers =
      client.headers
      |> Map.merge(%{
        "accept" => "application/json, text/event-stream",
        "content-type" => "application/json"
      })
      |> put_session(session)

    [
      url: client.url,
      headers: headers,
      receive_timeout: timeout,
      retry: false,
      decode_body: false
    ]
    |> Keyword.merge(plug_opt())
  end

  defp put_session(headers, id) when is_binary(id), do: Map.put(headers, "mcp-session-id", id)
  defp put_session(headers, _id), do: headers

  # Pinned in test (`HttpClientsAreStubbableTest`), unset everywhere else.
  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, []) |> Keyword.get(:plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end

  # A reply arrives as JSON or as a server-sent event stream, the server's
  # choice; either way it is the JSON-RPC message carrying this request's id.
  defp reply(response, id) do
    response
    |> messages()
    |> Enum.find(&(is_map(&1) and &1["id"] == id))
    |> case do
      %{"result" => result} -> {:ok, result}
      %{"error" => %{"message" => message}} -> {:error, message}
      %{"error" => error} -> {:error, inspect(error)}
      nil -> {:error, "the server's answer carried no reply to this request"}
    end
  end

  defp messages(response) do
    body = IO.iodata_to_binary(response.body)

    if event_stream?(response) do
      body
      |> String.split(~r/\r?\n\r?\n/, trim: true)
      |> Enum.map(&event_data/1)
      |> Enum.flat_map(&decoded/1)
    else
      decoded(body)
    end
  end

  defp event_stream?(response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  defp event_data(event) do
    event
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(fn
      "data:" <> data -> [String.trim_leading(data)]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp decoded(""), do: []

  defp decoded(text) do
    case Jason.decode(text) do
      {:ok, list} when is_list(list) -> list
      {:ok, message} -> [message]
      {:error, _} -> []
    end
  end
end
