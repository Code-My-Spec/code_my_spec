defmodule CodeMySpec.AgentTasks.Setup.CodemyspecDeps do
  @moduledoc """
  Setup step: required CodeMySpec dependencies present in mix.exs.
  """

  alias CodeMySpec.AgentTasks.Setup.Context

  def check(%Context{} = ctx) do
    case Context.error(ctx, "mix.exs", :codemyspec_deps, "`mix.exs` not synced") do
      nil -> :valid
      msg -> {:invalid, msg}
    end
  end

  def evaluate(scope, _task) do
    scope |> Context.load() |> check() |> wrap()
  end

  defp wrap(:valid), do: {:ok, :valid}
  defp wrap({:invalid, reason}), do: {:ok, :invalid, reason}

  def command(_scope, _task) do
    {:ok, """
    # Add CodeMySpec Dependencies

    Add to `deps/0` in `mix.exs`:

    - `:credo` — static code analysis
    - `:client_utils` — CodeMySpec client utilities
    - `:sobelow` — security-focused static analysis
    - `:sexy_spex` — BDD specification testing
    - `:boundary` — module dependency enforcement

    Then: `mix deps.get`
    """}
  end
end
