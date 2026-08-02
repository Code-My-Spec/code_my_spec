defmodule CodeMySpec.Provisioning.StepRepository do
  @moduledoc """
  Persistence for setup steps.

  Upserts on `(project_id, key)` so a re-run converges on one row per step
  rather than accumulating history — the sequence is a current state, and the
  audit trail of attempts lives in the run's own reporting.
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

  @doc "One step by key, or nil."
  @spec get(Scope.t(), atom()) :: Step.t() | nil
  def get(%Scope{active_project_id: nil}, _key), do: nil

  def get(%Scope{active_project_id: project_id}, key) do
    Repo.get_by(Step, project_id: project_id, key: key)
  end

  @doc """
  Create or update a step.

  Deliberately not `Repo.insert/2` with `on_conflict` — the changeset carries
  validations that a paused step names its instructions and an errored step
  names the provider's error, and an upsert that bypassed the changeset would
  bypass those too.
  """
  @spec upsert(Scope.t(), atom(), map()) :: Step.t()
  def upsert(%Scope{active_project_id: project_id} = scope, key, attrs) do
    attrs =
      attrs
      |> Map.put(:key, key)
      |> Map.put(:project_id, project_id)

    case get(scope, key) do
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
end
