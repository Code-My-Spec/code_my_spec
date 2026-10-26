defmodule CodeMySpec.Agents.ServedModels do
  @moduledoc """
  The models a provider actually serves this project, so a model choice is one
  that exists rather than free text. A default pinned to a model the Codex login
  had stopped serving crash-looped every Codex coder.

  Providers run on a machine's own login (Codex, the Claude CLI) are listed by
  the harness that runs them, reported at join. Anything not listed is
  `:unknown`: allowed, and said to be unverified, never blocked.
  """

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @doc """
  The models `provider` serves, or `:unknown`: from the project's copies, or,
  with no project (model settings are per user), from every copy in the account.
  """
  @spec list(Scope.t(), String.t()) :: {:ok, [String.t()]} | :unknown
  def list(%Scope{} = scope, provider) when is_binary(provider) do
    scope
    |> copy_ids()
    |> HarnessRegistry.served_models(provider)
    |> case do
      :unknown -> :unknown
      models -> {:ok, models}
    end
  end

  def list(_scope, _provider), do: :unknown

  defp copy_ids(%Scope{active_project_id: project_id} = scope) when is_binary(project_id),
    do: scope |> WorkingCopies.list_harnesses() |> Enum.map(& &1.id)

  defp copy_ids(%Scope{active_account_id: account_id}) when is_binary(account_id),
    do: WorkingCopies.ids_for_account(account_id)

  defp copy_ids(_scope), do: []

  @doc "Whether `provider` serves `model`: `true`, `false`, or `:unknown`."
  @spec served?(Scope.t(), String.t(), String.t() | nil) :: boolean() | :unknown
  def served?(_scope, _provider, nil), do: true

  def served?(scope, provider, model) do
    case list(scope, provider) do
      {:ok, models} -> model in models
      :unknown -> :unknown
    end
  end
end
