defmodule CmsHarness.CopyTools do
  @moduledoc """
  Runs one of the agents' own tools (`CoreTools`) in a working copy this
  harness serves, for Main, who names the copy on each call (issue e377de11).

  Main's call is a transport, not a second toolset: it reaches the same module
  a coder in that copy would run, with the context that copy's agents get, so
  output spills, `mix test` is routed through the copy's analysis service, and
  paths resolve the same way.
  """

  use Boundary, top_level?: true, deps: [CmsHarness.Agents], exports: :all

  alias CmsHarness.Agents.CoreTools
  alias CmsHarness.Agents.Engine.Impl

  @spec execute(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute(root, %{"tool" => name, "input" => input} = payload) when is_map(input) do
    case CoreTools.fetch(name) do
      {:ok, module} ->
        module.execute(input, context(root, payload))

      :error ->
        {:error,
         "Unknown tool #{inspect(name)}; use one of #{Enum.join(CoreTools.names(), ", ")}."}
    end
  end

  def execute(_root, _payload), do: {:error, "A copy tool call names a tool and its input."}

  # What the engine gives an agent working in this copy, with Main's own spill
  # directory and nothing of any agent's scratch.
  defp context(root, payload) do
    spill = Impl.spill_dir("main")

    %{
      working_directory: root,
      allowed_paths: [root, spill],
      bash_restricted: true,
      working_copy_id: payload["working_copy_id"],
      spill_dir: spill
    }
  end
end
