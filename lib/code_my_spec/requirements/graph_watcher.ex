defmodule CodeMySpec.Requirements.GraphWatcher do
  @moduledoc """
  Where callers start, settle and ask after a project's requirement graph writer.

  The writer is `IncrementalGraph`, which keeps the graph current from events as
  they arrive. Callers go through here so the sandbox allowance and the writer's
  scope are decided in one place.
  """

  alias CodeMySpec.Requirements.IncrementalGraph
  alias CodeMySpec.Requirements.SandboxAllowance
  alias CodeMySpec.Users.Scope

  @doc """
  Start this project's writer if nothing is writing it yet.

  Writers start with an agent, at boot for projects being worked, and on the
  first read of a project nothing has projected.
  """
  @spec ensure_watching(Scope.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_watching(%Scope{active_project_id: nil}), do: {:error, :no_project}

  def ensure_watching(%Scope{} = scope) do
    case IncrementalGraph.ensure_projecting(writer_scope(scope)) do
      {:ok, pid} -> {:ok, SandboxAllowance.grant(pid)}
      other -> other
    end
  end

  # The writer outlives the caller, so it keeps only who the project belongs
  # to, not the caller's session.
  defp writer_scope(%Scope{} = scope) do
    %Scope{
      user: scope.user,
      user_id: scope.user_id,
      active_account: scope.active_account,
      active_account_id: scope.active_account_id,
      active_project: scope.active_project,
      active_project_id: scope.active_project_id,
      active_working_copy_id: scope.active_working_copy_id
    }
  end

  @doc """
  Apply everything pending for this project, at this vantage, before answering.

  `:ok` for a project nothing is writing: a reader must not fail for wanting to
  be current.
  """
  @spec settle(Scope.t() | Ecto.UUID.t() | nil) :: :ok
  def settle(%Scope{active_project_id: project_id} = scope),
    do: settle(project_id, scope.active_working_copy_id)

  def settle(project_id) when is_binary(project_id), do: settle(project_id, nil)
  def settle(_no_project), do: :ok

  @spec settle(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: :ok
  def settle(project_id, vantage) when is_binary(project_id),
    do: IncrementalGraph.settle(project_id, [vantage])

  @doc "What this project's writer last did, or nil when nothing is writing it."
  @spec status(Ecto.UUID.t()) :: map() | nil
  def status(project_id), do: IncrementalGraph.status(project_id)
end
