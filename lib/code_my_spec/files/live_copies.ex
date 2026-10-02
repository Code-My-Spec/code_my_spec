defmodule CodeMySpec.Files.LiveCopies do
  @moduledoc """
  Which of a project's checkouts still speak for it.

  Old worktrees keep files the project has since deleted — metric_flow's dead
  ReviewMetrics component stayed alive on a stale checkout's spec — so a sync
  counts files only from live checkouts: the path is not missing, and the
  checkout is the main one or was seen within 7 days (3aeb66cf).
  """

  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @live_within_days 7

  @doc "Ids of `project_id`'s live checkouts."
  @spec ids(String.t()) :: [String.t()]
  def ids(project_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -@live_within_days * 86_400)

    Repo.all(
      from(w in WorkingCopy,
        where:
          w.project_id == ^project_id and is_nil(w.path_missing_since) and
            (w.main == true or w.last_seen_at > ^cutoff),
        select: w.id
      )
    )
  end
end
