defmodule CodeMySpec.Qa.Invalidations do
  @moduledoc """
  Domain functions for invalidating QA attempts.

  Invalidation is an audit action performed by an engineer. It stamps
  the event with the engineer's user ID, the current timestamp, and a
  mandatory non-empty reason. The original attempt is preserved.

  An attempt can be invalidated at most once — the second attempt
  returns `{:error, :already_invalidated}` rather than relying on the
  DB unique-constraint error message.
  """

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Qa.Invalidation
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc """
  Invalidate a prior QA attempt with a non-empty reason.

  Validates that `reason` is non-empty after trimming whitespace.
  Stamps `invalidated_by_user_id` from `scope.user.id` (nil for
  local-app scope where no user is authenticated) and
  `invalidated_at` from `DateTime.utc_now()` (microsecond precision).

  Pre-checks: the target attempt exists, and is not already
  invalidated.

  Returns `{:ok, invalidation}` or `{:error, changeset | atom}`.
  """
  @spec invalidate(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Invalidation.t()} | {:error, Ecto.Changeset.t() | atom()}
  def invalidate(%Scope{} = scope, attempt_id, reason) do
    with {:ok, _attempt} <- fetch_attempt(attempt_id),
         :ok <- ensure_not_invalidated(attempt_id) do
      attrs = %{
        qa_attempt_id: attempt_id,
        invalidated_by_user_id: scope_user_id(scope),
        reason: reason,
        invalidated_at: DateTime.utc_now()
      }

      %Invalidation{}
      |> Invalidation.changeset(attrs)
      |> Repo.insert()
    end
  end

  defp fetch_attempt(attempt_id) do
    case Repo.get(QaAttempt, attempt_id) do
      nil -> {:error, :attempt_not_found}
      attempt -> {:ok, attempt}
    end
  end

  defp ensure_not_invalidated(attempt_id) do
    exists? =
      Repo.exists?(from i in Invalidation, where: i.qa_attempt_id == ^attempt_id)

    if exists?, do: {:error, :already_invalidated}, else: :ok
  end

  # The local app's WorkingDirScope has no user — invalidations from
  # the local LiveView are stamped with the host (nil user_id) plus a
  # reason. The hosted SaaS scope carries a real `scope.user.id`.
  defp scope_user_id(%Scope{user: %{id: id}}) when not is_nil(id), do: id
  defp scope_user_id(_scope), do: nil
end
