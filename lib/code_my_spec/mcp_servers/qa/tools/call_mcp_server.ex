defmodule CodeMySpec.McpServers.Qa.Tools.CallMcpServer do
  @moduledoc """
  An MCP server driven as a client, so a QA agent can test one rather than use it.

  Every other tool an agent carries *is* a capability. This one is an
  instrument: it reaches whatever it is pointed at, and the agent is an
  ordinary caller of it — its own headers, its own session, and whatever the
  far side decides that caller may do.

  ## Why this is not "grant QA the tools it needs to test"

  Story 1008 is the fleet — agents starting, stopping, resolving their tools —
  and `50eac6ab` records a QA session that could not test it: `list_agents`,
  `list_agent_work` and `list_working_copies` all answered "is not a tool a qa
  agent carries". The obvious fix is to add those three to the qa role. It was
  tried and rejected, and the reasoning generalises:

  Granting a tool to the role that tests it conflates the tools an agent **works
  with** and the surface it is **testing**. Three tools for this story, the issue
  tools for the next, provisioning for the one after — and the role converges on
  everything, at which point scoping it means nothing.

  It also tests the wrong thing. An agent holding a tool exercises its *own*
  dispatch of it. The defects that matter live a layer out: whether the tool is
  mounted on the HTTP scope at all, whether the token identifies the caller,
  whether `X-Project-ID` scopes it. `50eac6ab`'s own finding was that
  `StartAgent` and `RestartAgent` "are not mounted on the hosted /mcp HTTP scope
  at all" — which no amount of carrying them would have revealed. John's call,
  2026-09-15.

  ## Why it is scriptable and not a tool the agent carries

  Story 1038's criterion 3015: an agent carries code mode's two ways in and
  `tool_docs`, and nothing else. Every direct tool is a schema the model re-reads
  on every turn to learn something it could have looked up once. A first version
  of this was a third direct tool and 3015 caught it, correctly. Reached from
  `run_script` it costs nothing until it is used, and `tool_docs` names it.

  ## One client per call, deliberately

  `CmsHarness.Mcp` holds a long-lived session per agent because an agent uses
  its tools all turn. A probe is the opposite: each call should be a fresh
  caller, because a warm session is exactly what a mounting or auth test must
  not inherit. So a client is started, used and stopped, under a name unique to
  the call.

  That also sidesteps two traps `Mcp.Transport.Anubis` documents at length and
  pays for at runtime — a leaked client holding a registered name, and Anubis
  keying an ETS table on `client_info["name"]` so two sessions sharing one name
  cannot both work. Unique names have neither problem.

  Nothing here speaks MCP by hand: `anubis_mcp` does the handshake, holds the
  session id and correlates replies.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators

  # Same ceiling the code-mode tools carry. A `tools/list` against a browser is
  # eighty-five entries, and an agent asking whether one name is present does not
  # need the rest in its context.
  @max_result_chars 24_000

  @default_timeout_ms 30_000

  # `start_link/1` returns before `initialize` has landed, so the first request
  # can be answered "Server capabilities not set" — which reads as a broken
  # server rather than a question asked too early. Waited on with the request the
  # caller was going to make anyway rather than with `ping`, because `ping` is
  # not a thing every server implements.
  @ready_attempts 20
  @ready_interval_ms 100

  @protocol_version "2025-06-18"

  schema do
    field :url, :string,
      required: true,
      description: "Base URL of the MCP server, e.g. http://localhost:4004"

    field :path, :string, description: "MCP path on that server. Defaults to /mcp."

    field :tool, :string, description: "Tool to call. Omit to list what the server offers."

    field :arguments, :map, description: "Arguments for the tool. Defaults to none."

    field :headers, :map,
      description: "Request headers, e.g. Authorization or X-Project-ID. Sent on the session."

    field :timeout, :integer, description: "Milliseconds for the call. Defaults to 30000."
  end

  @impl true
  def execute(%{url: url} = params, frame) when is_binary(url) and url != "" do
    with {:ok, _scope} <- Validators.validate_local_scope(frame) do
      {:reply, probe(url, params), frame}
    end
  end

  def execute(_params, frame) do
    {:reply, Response.error(Response.tool(), needs_a_url()), frame}
  end

  defp probe(url, params) do
    case connect(url, params) do
      {:ok, name} ->
        try do
          answer(request(name, params))
        after
          stop(name)
        end

      {:error, reason} ->
        Response.error(Response.tool(), unreachable(url, params, reason))
    end
  end

  defp connect(url, params) do
    name = unique_name()

    opts = [
      name: name,
      transport_name: :"#{name}_transport",
      transport:
        {:streamable_http, base_url: url, mcp_path: path(params), headers: headers(params)},
      client_info: %{"name" => Atom.to_string(name), "version" => "1.0.0"},
      capabilities: %{},
      protocol_version: @protocol_version
    ]

    case Anubis.Client.start_link(opts) do
      {:ok, supervisor} ->
        # Unlinked so a server that refuses the handshake fails this call rather
        # than the process running the script.
        Process.unlink(supervisor)
        ready(name, @ready_attempts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ready(name, attempts) do
    case safely(fn -> Anubis.Client.list_tools(name) end) do
      {:ok, _tools} ->
        {:ok, name}

      {:error, _reason} when attempts > 1 ->
        Process.sleep(@ready_interval_ms)
        ready(name, attempts - 1)

      {:error, reason} ->
        stop(name)
        {:error, reason}
    end
  end

  # A client whose transport cannot reach anything does not answer `{:error,
  # …}` — its supervisor shuts down, and the next `GenServer.call` to it exits
  # in the caller. That is the single most likely outcome of pointing this at a
  # URL, so letting it propagate would crash the script for the one case the
  # tool exists to report on.
  #
  # Translated rather than rescued away: the exit reason is the only thing that
  # distinguishes "nothing listening" from "the call took too long", and both
  # end up in the message a person reads.
  defp safely(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:session_died, reason}}
  end

  defp request(name, %{tool: tool} = params) when is_binary(tool) and tool != "" do
    call = fn -> Anubis.Client.call_tool(name, tool, arguments(params), timeout: timeout(params)) end

    case safely(call) do
      {:ok, %{is_error: true} = response} -> {:called_error, text(response)}
      {:ok, response} -> {:ok, text(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(name, _params) do
    case safely(fn -> Anubis.Client.list_tools(name) end) do
      {:ok, %{result: %{"tools" => tools}}} -> {:listed, Enum.map(tools, & &1["name"])}
      {:ok, other} -> {:error, {:unexpected_tool_list, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Named rather than counted. The question this answers is almost always "is
  # <name> there", and a count cannot answer it.
  defp answer({:listed, []}) do
    text_response("""
    The server answered and offers no tools at all.

    That is a different fault from a tool missing out of a populated list: the
    scope is reachable and empty, which usually means nothing is mounted on it
    rather than that this caller may not see them.
    """)
  end

  defp answer({:listed, names}) do
    text_response("#{length(names)} tool(s):\n" <> Enum.map_join(names, "\n", &"  #{&1}"))
  end

  defp answer({:ok, text}), do: text_response(text)

  # The far side answered and said the call failed. That is a result, not a
  # transport failure, and a QA agent testing error behaviour wants to read it
  # rather than have it raised as this tool's own failure.
  defp answer({:called_error, text}) do
    text_response("The server answered with an error result:\n\n" <> text)
  end

  defp answer({:error, reason}) do
    Response.error(Response.tool(), truncate(inspect(reason)))
  end

  defp unreachable(url, params, reason) do
    """
    Could not open an MCP session with #{url}#{path(params)}.

    #{truncate(inspect(reason))}

    Worth telling apart before reporting it: nothing listening at all, a path
    that is not an MCP mount, and a mount that refused this caller's headers all
    arrive here. A `tools/list` against a URL you know is good is the cheapest
    way to find out which.
    """
  end

  defp needs_a_url do
    """
    This needs a `url` — the base URL of the MCP server to call.

    Ours, for the usual cases:

      http://localhost:4004  path=/api/harnesses/<harness_id>/mcp   harness proxy
      http://localhost:4004  path=/mcp                              same, older spelling
    """
  end

  defp stop(name) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) -> GenServer.stop(pid, :normal, 5_000)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  # Unique per call, which is what makes one-client-per-call safe: Anubis keys
  # an ETS table on `client_info["name"]`, so two live sessions sharing a name
  # leave exactly one of them able to work.
  defp unique_name, do: :"mcp_probe_#{System.unique_integer([:positive, :monotonic])}"

  defp path(%{path: path}) when is_binary(path) and path != "", do: path
  defp path(_params), do: "/mcp"

  defp headers(%{headers: %{} = headers}), do: headers
  defp headers(_params), do: %{}

  defp arguments(%{arguments: %{} = arguments}), do: arguments
  defp arguments(_params), do: %{}

  defp timeout(%{timeout: ms}) when is_integer(ms) and ms > 0, do: ms
  defp timeout(_params), do: @default_timeout_ms

  defp text(%{result: %{"content" => content}}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp text(%{result: result}), do: inspect(result)
  defp text(other), do: inspect(other)

  defp text_response(content) do
    Response.text(Response.tool(), truncate(content))
  end

  defp truncate(text) when byte_size(text) <= @max_result_chars, do: text

  defp truncate(text) do
    note = "\n\n[truncated — the answer was longer than #{@max_result_chars} characters]"
    kept = @max_result_chars - byte_size(note)

    binary_part(text, 0, kept) <> note
  end
end
