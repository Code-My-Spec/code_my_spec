defmodule CodeMySpec.StoryReconcile do
  @moduledoc """
  Brings a project's story graph current with what its checkout has already
  shown: `mix cms.reconcile_status`. Plans first, writes only on `carry_out/2`, and
  only ever sets — it never clears a stamp.

  ## Ready-for-QA stamp

  A story whose newest QA attempt is an uninvalidated pass (`Qa.Verdict`) gets
  `qa_ready_commit` if it has none. QA attempts record no commit, so the stamp
  is HEAD.

  ## Un-park (opt-in)

  A parked story (`ready_for_dev: false`) with live criteria whose newest QA
  attempt passed is released. Eligibility reads `Qa.Verdict`, never the stamp.

  ## Order

  Releasing a story clears its ready-for-QA stamp and its `specs_ready` flag
  (`Story.changeset/2`'s readiness-change handling), so release runs before
  stamp. A released story that already had a stamp is stamped again with the
  commit and time it had, and one that was `specs_ready` gets it back, with its
  `specs_ready_at` and `specs_ready_commit`. The release loses nothing.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Qa.Verdict,
      CodeMySpec.Stories,
      CodeMySpec.Users.Scope,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  alias CodeMySpec.Qa.Verdict
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
    qa_passed = stories |> Enum.filter(&Verdict.complete?(scope, &1.id)) |> MapSet.new(& &1.id)

    unpark =
      if Keyword.get(opts, :unpark, false),
        do: plan_unpark(stories, criteria, qa_passed),
        else: :skipped

    qa_ready = plan_qa_ready(head, stories, qa_passed, released_ids(unpark))

    %{head: head, qa_ready: qa_ready, unpark: unpark}
  end

  @doc """
  Carries out a plan's changes: release, then stamp (see Order above).
  Refused and skipped steps write nothing.
  """
  @spec carry_out(Scope.t(), plan()) :: :ok | {:error, term()}
  def carry_out(%Scope{} = scope, plan) do
    with :ok <- each(plan.unpark, &release(scope, &1)) do
      each(plan.qa_ready, &stamp(scope, &1))
    end
  end

  # The release clears `specs_ready`; a story that had it gets it back as it was.
  defp release(scope, %{story: story}) do
    with {:ok, released} <- Stories.update_story(scope, story, %{ready_for_dev: true}) do
      if story.specs_ready,
        do:
          Stories.set_specs_ready(scope, released, true,
            at: story.specs_ready_at,
            commit: story.specs_ready_commit
          ),
        else: {:ok, released}
    end
  end

  # Re-read, because a release just cleared the stamp the planned struct still
  # carries, and a changeset against that struct would see no change to write.
  defp stamp(scope, item) do
    story = Stories.get_story!(scope, item.story.id)
    Stories.set_qa_ready(scope, story, item.after, item.at || DateTime.utc_now())
  end

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

  defp plan_qa_ready(head, stories, qa_passed, released) do
    passed = Enum.filter(stories, &MapSet.member?(qa_passed, &1.id))

    items =
      Enum.flat_map(passed, fn story ->
        case {story.qa_ready_commit, MapSet.member?(released, story.id)} do
          {nil, _} ->
            [%{story: story, before: "unstamped", after: head, at: nil, source: :head}]

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
