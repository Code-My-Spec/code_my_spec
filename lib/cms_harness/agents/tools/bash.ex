defmodule CmsHarness.Agents.Tools.Bash do
  @moduledoc """
  Bash with partial output retained when its deadline expires, and a long
  result spilled to a file (`Spill`) rather than cut: `Shell` holds every byte
  the command wrote, so nothing in the middle is lost.

  An agent's `mix test`/`mix spex` is routed through its copy's analysis
  service, as a Claude Code agent's is by the PreToolUse hook: the run is
  recorded and serialized with the copy's others. A routed run gets a suite's
  deadline rather than the 10s default only when no timeout is requested.
  """
  @behaviour Alloy.Tool

  alias CmsHarness.Agents.Shell
  alias CmsHarness.Agents.Spill
  alias CodeMySpec.Hooks.PreToolUse

  @impl true
  defdelegate name(), to: Alloy.Tool.Core.Bash
  @impl true
  defdelegate description(), to: Alloy.Tool.Core.Bash
  @impl true
  defdelegate input_schema(), to: Alloy.Tool.Core.Bash
  @impl true
  defdelegate concurrent?(), to: Alloy.Tool.Core.Bash
  @impl true
  defdelegate max_result_chars(), to: Alloy.Tool.Core.Bash

  @impl true
  def execute(input, context) do
    case run(input, context) do
      {:ok, text} -> {:ok, Spill.shape(text, context, name())}
      {:error, text} -> {:error, Spill.shape(text, context, name())}
    end
  end

  defp run(input, context) do
    dir = Map.get(context, :working_directory)

    copy_id = Map.get(context, :working_copy_id)

    case routed(input["command"], dir, copy_id) do
      {:routed, command, _what} ->
        case Shell.run(command, dir, timeout(input, PreToolUse.rewrite_timeout_ms())) do
          {:error, "Command timed out" <> _ = message} ->
            {:error, message <> timed_out(copy_id)}

          result ->
            result
        end

      :pass ->
        Shell.run(input["command"], dir, timeout(input, 10_000))
    end
  end

  # The run outlives the client, and nothing reports it to a caller that gave
  # up: six reports of a coder waiting on a finished run (run 59858 among them,
  # 2026-10-15), then a seventh (24f3668c) where no run id came back at all so
  # the caller could not even name which run to ask about.
  #
  # `get_analysis_output` answers that half without a run id: it already
  # selects a source's latest run in this working copy (`source` selector,
  # story 1032). The timed-out suite's own analyzer kill timer (55379e16,
  # `CmsHarness.Project.AnalysisServer`) already guarantees that run reaches a
  # terminal state on its own within its deadline; this just names the route
  # to read it rather than threading its id through a timed-out connection
  # that never received one.
  @doc false
  def timed_out(copy_id) do
    "\nServer-side analysis outcome is unknown; stopping the HTTP client does not " <>
      "cancel the analyzer, and no notice of its result will come. Do not start the " <>
      "suite again. To confirm this run's outcome, call `get_analysis_output` (via " <>
      "`run_script`) with `source` set to the analyzer this ran (exunit for mix test, " <>
      "spex for mix spex, credo for mix credo, compiler for mix compile): it reads " <>
      "that source's latest run in this working copy, no run id required, including " <>
      "one still running. If it needs to wait on this copy's analyzers going idle " <>
      "instead, run `curl -sS -X POST " <>
      "'http://localhost:#{port()}/api/harnesses/#{copy_id}/analysis/wait'` with a " <>
      "timeout of #{PreToolUse.rewrite_timeout_ms()}: it returns when this copy's " <>
      "analyzers are idle, with each source's state and problem count. " <>
      "GET /dashboard-status on this harness reports queued and running work " <>
      "alongside machine-wide slot usage while you wait."
  end

  defp timeout(input, default) do
    case input["timeout"] do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  @doc false
  @spec routed(String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:routed, String.t(), String.t()} | :pass
  def routed(command, dir, working_copy_id)
      when is_binary(command) and is_binary(working_copy_id) do
    case port() do
      port when is_integer(port) ->
        PreToolUse.route_command(command, dir, port, {:harness, working_copy_id})

      _ ->
        :pass
    end
  end

  def routed(_command, _dir, _working_copy_id), do: :pass

  defp port,
    do: get_in(Application.get_env(:code_my_spec, CmsHarness.Web.Endpoint, []), [:http, :port])
end
