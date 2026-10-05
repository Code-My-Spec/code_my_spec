defmodule CmsHarness.Agents.Tools.Bash do
  @moduledoc """
  Bash with partial output retained when its deadline expires.

  An agent's `mix test`/`mix spex` is routed through its copy's analysis
  service, as a Claude Code agent's is by the PreToolUse hook: the run is
  recorded and serialized with the copy's others. A routed run gets a suite's
  deadline rather than the 10s default.
  """
  @behaviour Alloy.Tool

  alias CmsHarness.Agents.Shell
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
    timeout =
      case input["timeout"] do
        value when is_integer(value) and value > 0 -> value
        _ -> 10_000
      end

    dir = Map.get(context, :working_directory)

    case routed(input["command"], dir, Map.get(context, :working_copy_id)) do
      {:routed, command, _what} ->
        Shell.run(command, dir, max(timeout, PreToolUse.rewrite_timeout_ms()))

      :pass ->
        Shell.run(input["command"], dir, timeout)
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
