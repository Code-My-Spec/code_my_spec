defmodule CodeMySpec.Architecture.Tools.CheckDecisions do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Architecture.DecisionCoverage
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.WorkingCopies

  @adr_glob ".code_my_spec/architecture/decisions/*.md"

  @impl true
  def name, do: "check_decisions"

  @impl true
  def description do
    """
    Compares the architecture decision records against `mix.exs` and reports where
    they disagree: a direct dependency no ADR covers, an ADR covering a dependency
    that is no longer there (a stale decision), or an ADR declining one that is.

    Each ADR declares what it covers in its frontmatter (`deps: [...]`,
    `declined: [...]`). An ADR covering nothing is fine. Reads `mix.exs` and the
    decision files once each.
    """
  end

  @impl true
  def params, do: %{}

  @impl true
  def call(_params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         env when not is_nil(env) <- WorkingCopies.execution_context(scope),
         {:ok, mix_exs} <- ExecutionContexts.read_file(env, "mix.exs") do
      adrs =
        env |> ExecutionContexts.glob(@adr_glob) |> Map.new(&{&1, read_adr(env, &1)})

      {:ok, mix_exs |> DecisionCoverage.check(adrs) |> DecisionCoverage.report()}
    else
      nil -> {:error, "No working environment: cannot read mix.exs and the decision records."}
      {:error, reason} -> {:error, "Could not read mix.exs: #{inspect(reason)}"}
    end
  end

  defp read_adr(env, path) do
    case ExecutionContexts.read_file(env, path) do
      {:ok, text} -> text
      {:error, _} -> ""
    end
  end
end
