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

    - `:boundary` — module dependency enforcement; supplies the `:boundary`
      compiler, so it must NOT be `only: :dev`
    - `:client_utils` — CodeMySpec client utilities; supplies the
      `:diagnostics` compiler, so it must NOT be `only: :dev`
    - `:credo` — static code analysis (`only: [:dev, :test], runtime: false`)
    - `:sobelow` — security-focused static analysis (same)
    - `:sexy_spex` — BDD specification testing (`only: [:dev, :test]`)
    - `:code_my_spec_generators` — `mix cms_gen.*` scaffolding (`only: :dev`)

    Then: `mix deps.get`
    """}
  end
end
