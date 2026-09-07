defmodule CodeMySpec.Provisioning.StepRepository do
  @moduledoc """
  Persistence for setup steps.

  Upserts on `(project_id, key, environment)` so a re-run converges on one row
  per step — or, for a step that runs independently per environment, one row
  per (step, environment) — rather than accumulating history. The sequence is
  a current state, and the audit trail of attempts lives in the run's own
  reporting.
  """

  import Ecto.Query

  alias CodeMySpec.Provisioning.Step
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc "Every step for the active project, in sequence order."
  @spec list(Scope.t()) :: [Step.t()]
  def list(%Scope{active_project_id: nil}), do: []

  def list(%Scope{active_project_id: project_id}) do
    Step
    |> where([s], s.project_id == ^project_id)
    |> order_by([s], asc: s.position)
    |> Repo.all()
  end

  @doc """
  One step by key, or nil. `environment` is nil for a project-wide step
  (the default) and a name for one environment's row of a per-environment
  step.
  """
  @spec get(Scope.t(), atom(), String.t() | nil) :: Step.t() | nil
  def get(scope, key, environment \\ nil)
  def get(%Scope{active_project_id: nil}, _key, _environment), do: nil

  def get(%Scope{active_project_id: project_id}, key, environment) do
    Step
    |> where([s], s.project_id == ^project_id and s.key == ^key)
    |> where_environment(environment)
    |> Repo.one()
  end

  # Ecto forbids `field == ^value` when `value` is nil at runtime — a
  # defensive check against exactly the bug a bare `==` would otherwise be,
  # since SQL's `= NULL` never matches anything. `is_nil/1` is the query
  # that actually means "the project-wide row."
  defp where_environment(query, nil), do: where(query, [s], is_nil(s.environment))
  defp where_environment(query, environment), do: where(query, [s], s.environment == ^environment)

  @doc """
  Create or update a step. `environment` is nil for a project-wide step and a
  name for one environment's row of a per-environment step —
  `Step.changeset/2` rejects a mismatch against `Sequence.scope/1`.

  Deliberately not `Repo.insert/2` with `on_conflict` — the changeset carries
  validations that a paused step names its instructions and an errored step
  names the provider's error, and an upsert that bypassed the changeset would
  bypass those too.
  """
  @spec upsert(Scope.t(), atom(), String.t() | nil, map()) :: Step.t()
  def upsert(%Scope{active_project_id: project_id} = scope, key, environment, attrs) do
    attrs =
      attrs
      |> Map.put(:key, key)
      |> Map.put(:environment, environment)
      |> Map.put(:project_id, project_id)

    case get(scope, key, environment) do
      nil ->
        %Step{}
        |> Step.changeset(attrs)
        |> Repo.insert!()

      existing ->
        existing
        |> Step.changeset(attrs)
        |> Repo.update!()
    end
  end

  @doc "Delete one environment's row for a step, if it exists. A no-op otherwise."
  @spec delete(Scope.t(), atom(), String.t()) :: :ok
  def delete(%Scope{active_project_id: nil}, _key, _environment), do: :ok

  def delete(%Scope{active_project_id: project_id}, key, environment) do
    Step
    |> where([s], s.project_id == ^project_id and s.key == ^key)
    |> where_environment(environment)
    |> Repo.delete_all()

    :ok
  end
end
