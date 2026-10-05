defmodule CmsHarness.Agents.Tools.Bash do
  @moduledoc "Bash with partial output retained when its deadline expires."
  @behaviour Alloy.Tool

  alias CmsHarness.Agents.Shell

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

    Shell.run(input["command"], Map.get(context, :working_directory), timeout)
  end
end
