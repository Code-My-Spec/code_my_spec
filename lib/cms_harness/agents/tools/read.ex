defmodule CmsHarness.Agents.Tools.Read do
  @moduledoc """
  Alloy's read tool, with a long result spilled to a file (`Spill`) instead of
  cut: a 1,500-line file read whole comes back as a notice the agent can page
  through with `offset`/`limit`.
  """

  @behaviour Alloy.Tool

  alias Alloy.Tool.Core.Read
  alias CmsHarness.Agents.Spill

  @impl true
  defdelegate name(), to: Read

  @impl true
  defdelegate description(), to: Read

  @impl true
  defdelegate input_schema(), to: Read

  @impl true
  defdelegate max_result_chars(), to: Read

  @impl true
  def execute(input, context) do
    case Read.execute(input, context) do
      {:ok, text} -> {:ok, Spill.shape(text, context, name())}
      other -> other
    end
  end
end
