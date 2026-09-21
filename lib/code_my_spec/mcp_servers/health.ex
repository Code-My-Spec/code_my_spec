defmodule CodeMySpec.McpServers.Health do
  @moduledoc """
  Proves the tool surface answers before an agent is handed anything.

  `machine_serves_tools/1` already asks whether a working copy *reported* any
  browser tools. That is a column lookup: it says a machine once described
  itself, not that a call placed now would come back. Nothing checked the MCP
  surface at all.

  This calls both halves of it — a direct tool and a Lua one through the
  scriptable catalog — and says whether they answered.

  ## Why it is worth the two calls

  On 2026-09-21 a night went into agents reporting that `run_script` and
  `get_next_requirement` were unreachable. They were not: nothing had been
  called at all, and the reports were fabricated. Establishing that took
  reading harness logs against model claims by hand, because there was no
  moment where the system had said, in its own voice, "the tools work".

  With this there is one. An agent that afterwards reports its tools missing is
  contradicting a check that ran seconds earlier, which is a different and much
  cheaper thing to diagnose than an open question.

  ## It reports, it does not wedge

  A failing probe refuses the launch, because an agent whose tools do not work
  produces plausible prose and no work, and that is worse than not starting.

  But a probe that *raises* answers `:ok`. A bug in here must not be able to
  stop every agent on the fleet from starting — the check is a convenience
  against a known failure, and a convenience that can take the system down is
  not one. It says so loudly in the log instead.
  """

  require Logger

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Health.Tools.{Health, ScriptHealth}

  @doc """
  `:ok` when both halves of the tool surface answered.

  `{:error, {:tool_surface_silent, names}}` naming the ones that did not.
  """
  @spec probe() :: :ok | {:error, {:tool_surface_silent, [String.t()]}}
  def probe do
    case Enum.reject([{"health", Health}, {"script_health", ScriptHealth}], &answers?/1) do
      [] ->
        :ok

      silent ->
        names = Enum.map(silent, &elem(&1, 0))
        Logger.error("[Health] tool surface did not answer: #{Enum.join(names, ", ")}")
        {:error, {:tool_surface_silent, names}}
    end
  end

  defp answers?({_name, module}) do
    {:reply, response, _frame} = module.execute(%{}, %Frame{})

    response
    |> Response.to_protocol()
    |> Map.get("content")
    |> case do
      [%{"text" => "ok"} | _] -> true
      _ -> false
    end
  rescue
    error ->
      # Loudly, and then out of the way. See "It reports, it does not wedge".
      Logger.error("[Health] probe raised, treating the surface as live: #{inspect(error)}")
      true
  end
end
