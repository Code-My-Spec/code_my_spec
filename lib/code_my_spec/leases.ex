defmodule CodeMySpec.Leases do
  @moduledoc """
  One harness at a time owns a project's files.

  Files, components and problems are per-project rows rather than
  per-checkout ones. Two harnesses pointed at the same project each sync their
  own working copy into that single set of rows, and each sync removes what the
  other just wrote; the requirement graph, computed from those rows, then
  describes neither checkout. Agents on both sides work from it and neither is
  wrong in a way anybody notices until much later.

  ## The lock is the lease

  A Postgres advisory lock held on `Leases.Session`'s connection. Postgres drops
  it when that connection closes, so a harness that dies — panic, `docker rm
  -f`, OOM — frees its projects as the socket closes.

  This started out as a row with an expiry and a heartbeat, which needed a timer
  to renew and left a window where a dead harness still nominally owned a
  project. The timer only existed to compensate for the deadline, and the
  deadline only existed because the first design was store-agnostic. It did not
  need to be: the corruption this prevents is only possible on a shared
  Postgres, and a SQLite harness has its own database and nothing to collide
  with.

  ## The row is a label, not the authority

  `project_leases` survives so a refusal can say *which checkout* to go and
  stop — an advisory lock is two integers and cannot tell you that. The lock
  decides; the row is written after the fact and read only for the message. A
  row left behind by a crashed harness is stale but harmless, because acquiring
  consults the lock and then overwrites it.
  """

  use Boundary, deps: [CodeMySpec, CodeMySpec.Repo], exports: :all

  alias CodeMySpec.Leases.ProjectLease
  alias CodeMySpec.Leases.Session
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @type acquire_error :: {:held_by, String.t()}

  @doc """
  Claim this project's files, or report who already has them.

  Succeeds if this harness already holds the lock — advisory locks are
  re-entrant per session, so the startup path and a re-check are the same call.
  """
  @spec acquire(Scope.t(), String.t() | nil) :: :ok | {:error, acquire_error()}
  def acquire(%Scope{active_project_id: project_id}, label \\ nil)
      when is_binary(project_id) do
    if Session.try_lock(project_id) do
      note_holder(project_id, label)
      :ok
    else
      {:error, {:held_by, holder_label(project_id)}}
    end
  end

  @doc """
  Give up this project.

  Rarely needed: the lock goes when the session does. Worth calling on a clean
  shutdown so the next harness starts immediately rather than after the old
  connection is reaped.
  """
  @spec release(Scope.t()) :: :ok
  def release(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Session.unlock(project_id)
    Repo.delete_all(from_project(project_id))
    :ok
  end

  @doc """
  The label of whoever holds this project, or `nil` if it is free.

  Asks the lock, not the row — a row can outlive the harness that wrote it.
  """
  @spec holder(Scope.t()) :: String.t() | nil
  def holder(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    if Session.try_lock(project_id) do
      # We just took it, so it was free. Give it straight back: asking who holds
      # a project must not be the thing that claims it.
      Session.unlock(project_id)
      nil
    else
      holder_label(project_id)
    end
  end

  @doc """
  A label for a harness instance, for the refusal message.

  Says where it is rather than who it is: the person reading it needs to know
  which checkout to go and stop.
  """
  @spec describe(String.t() | nil) :: String.t()
  def describe(nil), do: "another harness"
  def describe(working_dir), do: "the harness at #{working_dir}"

  # -- Internals --

  defp from_project(project_id) do
    import Ecto.Query, only: [where: 3]
    where(ProjectLease, [l], l.project_id == ^project_id)
  end

  defp holder_label(project_id) do
    case Repo.get_by(ProjectLease, project_id: project_id) do
      %ProjectLease{holder_label: label} when is_binary(label) -> label
      _ -> "another harness"
    end
  end

  # Best-effort. The lock is already held by the time this runs, so failing to
  # record the label costs a worse error message and nothing else.
  defp note_holder(project_id, label) do
    Repo.insert(
      %ProjectLease{project_id: project_id, holder_label: label},
      on_conflict: [set: [holder_label: label, updated_at: DateTime.utc_now()]],
      conflict_target: :project_id
    )
  rescue
    _ -> :ok
  end
end
