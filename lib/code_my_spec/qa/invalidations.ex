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
  alias CodeMySpec.Qa.QaAttempts
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphInputs
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
    with {:ok, _attempt} <- fetch_attempt(scope, attempt_id),
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
      |> tap(&announce_graph_change(scope, &1))
    end
  end

  # Rejecting a pass moves the graph exactly as submitting one does, and
  # nothing said so.
  #
  # `QaAttempts.submit/2` announces; this did not, so `qa_complete` went on
  # reporting a pass an engineer had explicitly thrown out until some unrelated
  # input happened to move. Measured 2026-09-20: nine passes across seven
  # stories were invalidated and every `qa_complete` row still read satisfied,
  # until a rescan for a different reason recomputed the graph minutes later.
  #
  # The same event kind as a submission, because it is the same fact about the
  # same requirement — the story's newest valid attempt has changed — and
  # `Requirements.Handlers` settles `qa_complete` from that either way.
  defp announce_graph_change(scope, {:ok, invalidation}) do
    GraphInputs.event(
      scope,
      "Qa",
      "qa_attempt_submitted",
      %{},
      story_entities(scope, invalidation),
      # A verdict about the story, not about the tree it was run against.
      :project_wide
    )
  end

  defp announce_graph_change(_scope, _other), do: :ok

  defp story_entities(scope, %Invalidation{qa_attempt_id: attempt_id}) do
    case QaAttempts.get_in_project(scope, attempt_id) do
      %{story_id: story_id} when not is_nil(story_id) -> [{"story", story_id}]
      _ -> []
    end
  end

  # Scoped to the caller's project, which it was not.
  #
  # This takes a `%Scope{}` and used it only to stamp *who* invalidated —
  # `Repo.get(QaAttempt, attempt_id)` authorised nothing, so an agent working one
  # project could invalidate another project's QA attempt by id, and the
  # invalidation would be recorded against them as though it were theirs. The
  # docstring's "Pre-checks: the target attempt exists" was accurate and was the
  # whole of it.
  #
  # Same shape as b3f08e21 in `InvitationRepository`: a function holding a scope
  # and reading past it. Found by auditing for that shape rather than from a
  # report.
  #
  # `QaAttempts.get_in_project/2` rather than a join here, because that module
  # owns attempt queries and its `by_project/2` already fails closed on a scope
  # with no active project.
  defp fetch_attempt(scope, attempt_id) do
    case QaAttempts.get_in_project(scope, attempt_id) do
      nil -> {:error, :attempt_not_found}
      attempt -> {:ok, attempt}
    end
  end

  defp ensure_not_invalidated(attempt_id) do
    exists? =
      Repo.exists?(from i in Invalidation, where: i.qa_attempt_id == ^attempt_id)

    if exists?, do: {:error, :already_invalidated}, else: :ok
  end

  # The local app's harness-resolved scope has no user — invalidations from
  # the local LiveView are stamped with the host (nil user_id) plus a
  # reason. The hosted SaaS scope carries a real `scope.user.id`.
  defp scope_user_id(%Scope{user: %{id: id}}) when not is_nil(id), do: id
  defp scope_user_id(_scope), do: nil
end
