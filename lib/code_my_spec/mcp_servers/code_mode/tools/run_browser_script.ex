defmodule CodeMySpec.McpServers.CodeMode.Tools.RunBrowserScript do
  @moduledoc """
  Run a Lua script against the browser on this project's machine.

      browser_navigate({ url = "http://127.0.0.1:4000/app" })
      browser_wait_for_text({ text = "Overview", timeout = 20000 })
      return browser_get_url({})

  Separate from `run_script`, and separate on purpose. The browser's tools are a
  different kind of thing under a wall clock: several of them **wait by design**
  — `browser_wait_for_text`, `browser_wait_for_url` and `browser_sleep` all take
  a duration from the caller — while ours are database reads that answer in
  milliseconds.

  One deadline cannot be right for both. Sharing one made that concrete: a
  browser call was given a hardcoded 30 seconds inside a script whose own wall
  clock was also 30 seconds, so they expired together, and a call that used its
  budget left the script nothing to do with the answer.

  So this sandbox takes a `timeout` from the caller, defaults to a minute, and
  the browser tools live only here. They do not need to interact with ours in
  one script — a value that has to cross between them crosses through the
  agent's turn, which costs a call and buys a deadline that fits.

  ## `timeout`

  Milliseconds, for the whole script rather than any one call. Each browser call
  inside it is given the remaining budget less a small margin, so a call that
  hangs reports as a timeout rather than being taken out by the sandbox at the
  same instant.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.CodeMode
  alias CodeMySpec.CodeMode.Result
  alias CodeMySpec.McpServers.CodeMode, as: Layer
  alias CodeMySpec.McpServers.Validators

  # A minute, because a page load and a login round trip fit in it and an agent
  # waiting on a browser is waiting on something a person could watch. John's
  # number.
  @default_timeout_ms 60_000

  # Long enough for a `browser_start` that is slow rather than stuck. Past this
  # the answer is that something is wrong, and no larger value makes a hung
  # Chrome finish.
  @max_timeout_ms 300_000

  schema do
    field :script, :string,
      required: true,
      description: "Lua source. Return a value to get it back; use print() for progress."

    field :timeout, :integer,
      description:
        "Milliseconds for the whole script. Defaults to 60000, capped at 300000. " <>
          "Raise it for a page that is slow, not for one that is stuck."

    field :agent_id, :string,
      description:
        "The agent running this, when one is. Its row says which machine tools it " <>
          "carries; omitted, the script may call everything the caller can."
  end

  @impl true
  def execute(%{script: script} = params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        timeout = timeout(params)
        allowed = allowed_tools(scope, Map.get(params, :agent_id))

        result =
          scope
          |> Layer.machine_catalog(allowed, timeout)
          |> CodeMode.eval(script, timeout: timeout)

        {:reply, render(result, scope), frame}

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{inspect(reason)}"), frame}
    end
  end

  defp timeout(%{timeout: ms}) when is_integer(ms) and ms > 0,
    do: min(ms, @max_timeout_ms)

  defp timeout(_params), do: @default_timeout_ms

  # Same rule as `run_script`: the caller names which agent it is, and the
  # server reads what that agent carries off its own row.
  defp allowed_tools(_scope, nil), do: nil

  defp allowed_tools(scope, agent_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(agent_id),
         {:ok, agent} <- CodeMySpec.Agents.fetch_agent(scope, agent_id) do
      agent.tools
    else
      _ -> nil
    end
  end

  defp render(%Result{} = result, scope) do
    case Result.failed?(result) do
      true -> Response.tool() |> Response.error(failure(result, scope))
      false -> Response.tool() |> Response.text(success(result))
    end
  end

  defp success(result) do
    [printed(result), value(result.value)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # Same shape as `run_script`'s, plus one thing only this sandbox can say. A
  # machine with no browser is the commonest reason a script here finds nothing
  # to call, and Lua answers that as "attempt to call a nil value", which reads
  # as a typo. The remedy is on the machine rather than in the script, so it is
  # named before the error rather than left to be inferred from it.
  defp failure(%Result{error: error} = result, scope) do
    [hint(scope), printed(result), "#{error.kind}: #{error.message}"]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp hint(scope) do
    case Layer.machine_tool_names(scope) do
      [] ->
        "This project's machine reports no browser tools, so there is nothing here " <>
          "to call. Check the harness is connected and that its machine reported a " <>
          "browser."

      _ ->
        ""
    end
  end

  defp printed(%Result{printed: []}), do: ""
  defp printed(%Result{printed: lines}), do: "Output:\n" <> Enum.join(lines, "\n")

  defp value(nil), do: ""
  defp value(value) when is_binary(value), do: "Returned:\n" <> value

  defp value(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> "Returned:\n" <> json
      {:error, _reason} -> "Returned:\n" <> inspect(value, pretty: true)
    end
  end
end
