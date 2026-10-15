defmodule CodeMySpec.StoryReconcile do
  @moduledoc """
  Plans reconciliation without inventing QA evidence. A captured QA review must
  still match the story's certified revision and current submitted issue bag.

  With `--unpark`, eligible parked stories are released. The exact existing
  certification and specs-ready stamp are preserved atomically; checkout HEAD
  is informational and never substituted for the revision QA reviewed.
  Plans are revalidated under the story lock before applying any changes.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Qa,
      CodeMySpec.Repo,
      CodeMySpec.Stories,
      CodeMySpec.Users.Scope,
      CodeMySpec.WorkingCopies
    ]

  import Ecto.Query

  alias CodeMySpec.Qa
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @type step(item) :: {:ok, [item], map()} | {:refused, String.t(), [item]} | :skipped
  @type plan :: %{
          head: String.t(),
          qa_ready: step(map()),
          unpark: step(map())
        }

  @doc """
  `scope` bound to the working copy served from `root`, which is what scopes
  runs, Problems and files to this checkout. `{:error, message}` when no copy
  of the project is registered at `root`.
  """
  @spec bind_checkout(Scope.t(), String.t()) :: {:ok, Scope.t()} | {:error, String.t()}
  def bind_checkout(%Scope{} = scope, root) do
    root = Path.expand(root)

    case Enum.find(WorkingCopies.list_harnesses(scope), &(&1.root == root)) do
      nil ->
        {:error,
         "No working copy of this project is registered at #{root}. Start the harness in " <>
           "that checkout so its analysis runs are recorded against it, then re-run."}

      copy ->
        {:ok, %{scope | active_working_copy_id: copy.id}}
    end
  end

  @doc """
  What reconciling would do. `opts`: `:head` (required, the checkout's HEAD),
  `:unpark` (default false).
  """
  @spec plan(Scope.t(), keyword()) :: plan()
  def plan(%Scope{} = scope, opts) do
    head = Keyword.fetch!(opts, :head)
    {:ok, stories} = Stories.list_project_stories(scope)
    stories = Enum.sort_by(stories, & &1.number)
    criteria = Map.new(stories, &{&1.id, AcceptanceCriteria.list_story_criteria(scope, &1.id)})

    qa_passed =
      stories |> Enum.filter(&Qa.story_review_current?(scope, &1.id)) |> MapSet.new(& &1.id)

    unpark =
      if Keyword.get(opts, :unpark, false),
        do: plan_unpark(stories, criteria, qa_passed),
        else: :skipped

    qa_ready = plan_qa_ready(stories, qa_passed, released_ids(unpark))

    %{head: head, qa_ready: qa_ready, unpark: unpark}
  end

  @doc "Apply releases while preserving only the exact certification already reviewed."
  @spec carry_out(Scope.t(), plan()) :: :ok | {:error, term()}
  def carry_out(%Scope{} = scope, plan) do
    case Repo.transaction(fn -> release_all(scope, plan.unpark) end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_all(scope, unpark) do
    case each(unpark, &release(scope, &1)) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp release(scope, %{story: planned}) do
    Repo.one!(
      from(s in "stories",
        where: s.id == ^planned.id and s.project_id == type(^scope.active_project_id, :binary_id),
        select: s.id,
        lock: "FOR UPDATE"
      )
    )

    story = Stories.get_story!(scope, planned.id)

    if unchanged_plan?(story, planned) and Qa.story_review_current?(scope, story.id) do
      with {:ok, released} <- Stories.update_story(scope, story, %{ready_for_dev: true}),
           {:ok, released} <- restore_specs(scope, released, story) do
        Stories.set_qa_ready(
          scope,
          released,
          story.qa_ready_commit,
          story.qa_ready_at,
          {story.qa_reviewed_commit, story.qa_reviewed_at}
        )
      end
    else
      {:error, :story_reconcile_plan_stale}
    end
  end

  defp unchanged_plan?(story, planned) do
    fields = [
      :ready_for_dev,
      :qa_ready_commit,
      :qa_ready_at,
      :qa_reviewed_commit,
      :qa_reviewed_at,
      :specs_ready,
      :specs_ready_at,
      :specs_ready_commit
    ]

    Map.take(story, fields) == Map.take(planned, fields)
  end

  defp restore_specs(scope, released, %{specs_ready: true} = story),
    do:
      Stories.set_specs_ready(scope, released, true,
        at: story.specs_ready_at,
        commit: story.specs_ready_commit
      )

  defp restore_specs(_scope, released, _story), do: {:ok, released}

  defp each({:ok, items, _counts}, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {item, reason}}}
      end
    end)
  end

  defp each(_step, _fun), do: :ok

  # -- 2. ready-for-QA stamp --

  defp plan_qa_ready(stories, qa_passed, released) do
    passed = Enum.filter(stories, &MapSet.member?(qa_passed, &1.id))

    items =
      Enum.flat_map(passed, fn story ->
        case {story.qa_ready_commit, MapSet.member?(released, story.id)} do
          {commit, true} ->
            [
              %{
                story: story,
                before: "cleared by un-park",
                after: commit,
                at: story.qa_ready_at,
                source: :kept
              }
            ]

          {_commit, false} ->
            []
        end
      end)

    already = Enum.count(passed, &(&1.qa_ready_commit && not MapSet.member?(released, &1.id)))
    {:ok, items, %{already: already}}
  end

  # -- 3. un-park --

  defp plan_unpark(stories, criteria, qa_passed) do
    items =
      for story <- stories,
          story.ready_for_dev == false,
          MapSet.member?(qa_passed, story.id),
          live <- [criteria[story.id]],
          live != [],
          do: %{story: story, before: "parked", after: "ready_for_dev"}

    {:ok, items, %{}}
  end

  defp released_ids({:ok, items, _counts}), do: MapSet.new(items, & &1.story.id)
  defp released_ids(_step), do: MapSet.new()
end
