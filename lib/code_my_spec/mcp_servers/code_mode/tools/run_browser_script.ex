defmodule CodeMySpec.McpServers.CodeMode.Tools.RunBrowserScript do
  @moduledoc """
  Run a Lua script against the browser on this project's machine.

      browser_navigate({ url = "http://127.0.0.1:4000/app" })
      browser_wait_for_text({ text = "Overview", timeout = 20000 })
      return browser_get_url({})

  Tool names come from the machine, not from Playwright or Puppeteer — look
  them up with `tool_docs({ search = "wait" })` or `tool_docs({ name = "..." })`
  (called directly, not from inside a script) before guessing. A nil global
  means the name is wrong, not that the browser is broken; see
  `read_knowledge({ path = "qa-tooling/vibium_reference.md" })` for common
  mistakes.

  Separate from `run_script` because browser tools wait — for a page, an
  element, a redirect — on their own `timeout`, not the project's fast ones.
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
  # server derives what that agent may call from its role.
  defp allowed_tools(_scope, nil), do: nil

  defp allowed_tools(scope, agent_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(agent_id),
         {:ok, agent} <- CodeMySpec.Agents.fetch_agent(scope, agent_id) do
      CodeMySpec.Agents.tools_of(scope, agent)
    else
      _ -> nil
    end
  end

  defp render(%Result{} = result, scope) do
    if Result.failed?(result),
      do: Response.tool() |> Response.error(failure(result, scope)),
      else: Response.tool() |> Response.text(success(result))
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
