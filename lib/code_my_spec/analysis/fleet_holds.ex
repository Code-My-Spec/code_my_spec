defmodule CodeMySpec.Analysis.FleetHolds do
  @moduledoc """
  Place, lift and read a project's fleet hold.

  At most one hold is ever active per project (`fleet_holds_one_active_per_project`).
  Placing while one already stands answers the standing hold rather than making
  a second -- a repeated broadcast is not a second hold. Nothing here touches
  work already admitted: `Analysis.start_run/4` and `Analysis.await_run/4`
  check `active/1` once, at the top, before opening anything.
  """
  import Ecto.Query

  alias CodeMySpec.Analysis.FleetHold
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc "Place a hold, or answer the one already active."
  @spec place(Scope.t(), String.t(), keyword()) ::
          {:ok, FleetHold.t()} | {:error, Ecto.Changeset.t()}
  def place(%Scope{active_project_id: project_id}, reason, opts \\ []) when is_binary(reason) do
    case project_id |> active_query() |> Repo.one() do
      %FleetHold{} = hold ->
        {:ok, hold}

      nil ->
        %FleetHold{}
        |> FleetHold.changeset(%{
          project_id: project_id,
          reason: reason,
          placed_by: Keyword.get(opts, :placed_by, "operator"),
          status: :active
        })
        |> Repo.insert()
    end
  end

  @doc "Lift the active hold. `{:error, :no_active_hold}` when none stands."
  @spec lift(Scope.t(), keyword()) :: {:ok, FleetHold.t()} | {:error, :no_active_hold}
  def lift(%Scope{active_project_id: project_id}, opts \\ []) do
    case project_id |> active_query() |> Repo.one() do
      nil ->
        {:error, :no_active_hold}

      %FleetHold{} = hold ->
        hold
        |> FleetHold.changeset(%{
          status: :lifted,
          lifted_by: Keyword.get(opts, :lifted_by, "operator"),
          lifted_at: DateTime.utc_now()
        })
        |> Repo.update()
    end
  end

  @doc "The active hold on this project's new work, or nil."
  @spec active(Scope.t()) :: FleetHold.t() | nil
  def active(%Scope{active_project_id: project_id}),
    do: project_id |> active_query() |> Repo.one()

  defp active_query(project_id),
    do: from(h in FleetHold, where: h.project_id == ^project_id and h.status == :active)

  @doc "The refusal text for a held project: names the reason, never silently drops work."
  @spec refusal(FleetHold.t()) :: String.t()
  def refusal(%FleetHold{reason: reason, inserted_at: at}) do
    "A fleet hold is in force (placed #{DateTime.to_iso8601(at)}): #{reason}. New analyzer " <>
      "runs and task claims are refused until it lifts; work already running or already " <>
      "claimed is unaffected."
  end
end
