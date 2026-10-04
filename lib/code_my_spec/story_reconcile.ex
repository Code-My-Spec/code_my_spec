defmodule CodeMySpec.StoryReconcile do
  @moduledoc """
  Brings a project's story graph current with what its checkout has already
  shown: `mix cms.reconcile_status`. Plans first, writes only on `carry_out/2`, and
  only ever sets — it never unlatches a criterion or clears a stamp.

  ## 1. Latch passing criteria

  The run read is the checkout's latest completed full spex run, and only when
  it answers for HEAD (`Analysis.answer_at_commit/3`: started on a clean tree at
  HEAD and finished there). Not merely the latest run *at* HEAD: Problems carry
  no run id, and a full run replaces its source's Problems wholesale, so the
  `spex` Problems on this working copy are the latest completed run's and no
  other's. An older run at HEAD behind a newer one says nothing about them.

  A full run takes bare args, so it swept every spex file on disk. With the
  tree clean at HEAD, that is every spex file tracked at HEAD (`:head_paths`);
  a file not in HEAD is not credited, whatever the run saw.

  A spex file covers the criterion whose number its `spex` call names
  (`files.criterion_number`, role `:bdd_spec`). A live criterion passed when it
  has at least one such file, every one of them is tracked at HEAD, and none
  has a `spex` Problem. A failure the analyzer filed against no spec file could
  belong to any criterion, so any such Problem refuses the whole step.

  ## 2. Ready-for-QA stamp

  A story whose newest QA attempt is an uninvalidated pass (`Qa.Verdict`) gets
  `qa_ready_commit` if it has none. QA attempts record no commit, so the stamp
  is HEAD.

  ## 3. Un-park (opt-in)

  A parked story (`ready_for_dev: false`) whose live criteria are all latched
  (counting step 1's) and whose newest QA attempt passed is released.
  Eligibility reads latches and `Qa.Verdict`, never the stamp.

  ## Order

  Releasing a story clears its ready-for-QA stamp and its story-level
  `specs_ready` latch (`Story.changeset/2`'s readiness-change handling, kept by
  story 983; criterion latches survive). So the steps run 1, 3, 2: latch,
  release, then stamp. A released story that already had a stamp is stamped
  again with the commit and time it had. A released story that was
  `specs_ready` gets that latch back, with its `specs_ready_at` and
  `specs_ready_commit`, straight after the release: gating reads it
  (`Validation.Blocking`), so losing it would quietly stop the story's red
  spex from blocking. The release loses nothing.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Analysis,
      CodeMySpec.Files,
      CodeMySpec.Problems,
      CodeMySpec.Qa.Verdict,
      CodeMySpec.Stories,
      CodeMySpec.Users.Scope,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Files
  alias CodeMySpec.Problems.ProblemRepository
  alias CodeMySpec.Qa.Verdict
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @type step(item) :: {:ok, [item], map()} | {:refused, String.t(), [item]} | :skipped
  @type plan :: %{
          head: String.t(),
          latch: step(map()),
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
  `:head_paths` (required, paths tracked at HEAD), `:unpark` (default false).
  """
  @spec plan(Scope.t(), keyword()) :: plan()
  def plan(%Scope{} = scope, opts) do
    head = Keyword.fetch!(opts, :head)
    head_paths = opts |> Keyword.fetch!(:head_paths) |> MapSet.new()
    {:ok, stories} = Stories.list_project_stories(scope)
    stories = Enum.sort_by(stories, & &1.number)
    criteria = Map.new(stories, &{&1.id, AcceptanceCriteria.list_story_criteria(scope, &1.id)})
    qa_passed = stories |> Enum.filter(&Verdict.complete?(scope, &1.id)) |> MapSet.new(& &1.id)

    latch = plan_latch(scope, head, head_paths, stories, criteria)

    unpark =
      if Keyword.get(opts, :unpark, false),
        do: plan_unpark(stories, criteria, qa_passed, latched_ids(latch)),
        else: :skipped

    qa_ready = plan_qa_ready(head, stories, qa_passed, released_ids(unpark))

    %{head: head, latch: latch, qa_ready: qa_ready, unpark: unpark}
  end

  @doc """
  Carries out a plan's changes: latch, release, then stamp (see Order above).
  Refused and skipped steps write nothing.
  """
  @spec carry_out(Scope.t(), plan()) :: :ok | {:error, term()}
  def carry_out(%Scope{} = scope, plan) do
    with :ok <- each(plan.latch, &AcceptanceCriteria.latch_criterion(scope, &1.criterion)),
         :ok <- each(plan.unpark, &release(scope, &1)) do
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

  # -- 1. latch --

  defp plan_latch(%Scope{active_working_copy_id: nil}, _head, _paths, _stories, _criteria),
    do: {:refused, "The scope names no working copy, so its runs cannot be told apart.", []}

  defp plan_latch(scope, head, head_paths, stories, criteria) do
    case Analysis.answer_at_commit(scope, "spex", head) do
      nil -> {:refused, no_run_message(scope, head), []}
      %Run{} = run -> latch_from_run(scope, run, head_paths, stories, criteria)
    end
  end

  defp latch_from_run(scope, run, head_paths, stories, criteria) do
    specs = Files.list_files_with_role(scope, :bdd_spec)
    spec_paths = MapSet.new(specs, & &1.path)
    failing = ProblemRepository.list_project_problems(scope, source: "spex")

    case Enum.reject(failing, &MapSet.member?(spec_paths, &1.file_path)) do
      [] ->
        failing_paths = MapSet.new(failing, & &1.file_path)

        by_number =
          specs |> Enum.filter(& &1.criterion_number) |> Enum.group_by(& &1.criterion_number)

        verdict = &criterion_verdict(&1, by_number, head_paths, failing_paths)
        tally(stories, criteria, run, verdict)

      unattributed ->
        {:refused,
         "Spex run #{run.id} has #{length(unattributed)} failure(s) filed against no spec " <>
           "file (#{unattributed |> Enum.map(& &1.file_path) |> Enum.uniq() |> Enum.join(", ")}). " <>
           "They could belong to any criterion, so nothing is latched. Fix them and re-run analysis.",
         []}
    end
  end

  defp tally(stories, criteria, run, verdict) do
    rows =
      for story <- stories, criterion <- Enum.sort_by(criteria[story.id], & &1.number) do
        {story, criterion, if(criterion.latched_at, do: :already, else: verdict.(criterion))}
      end

    items =
      for {story, criterion, :passed} <- rows,
          do: %{story: story, criterion: criterion, before: "unlatched", after: "latched"}

    counts =
      rows
      |> Enum.frequencies_by(&elem(&1, 2))
      |> Map.put(:run_id, run.id)

    {:ok, items, counts}
  end

  defp criterion_verdict(criterion, by_number, head_paths, failing_paths) do
    case Map.get(by_number, criterion.number, []) do
      [] ->
        :no_spex

      files ->
        cond do
          not Enum.all?(files, &MapSet.member?(head_paths, &1.path)) -> :not_at_head
          Enum.any?(files, &MapSet.member?(failing_paths, &1.path)) -> :failing
          true -> :passed
        end
    end
  end

  defp no_run_message(scope, head) do
    latest =
      case Analysis.latest_answer(scope, "spex") do
        nil ->
          "This checkout has no completed spex run at all."

        run ->
          "Its latest completed spex run (#{run.id}) started at " <>
            "#{run.start_commit || "an unrecorded commit"}" <>
            if(run.start_tree_dirty, do: " on a dirty tree", else: "") <>
            ", finished at #{run.completed_commit || "an unrecorded commit"}."
      end

    "No completed spex run answers for HEAD #{head}. #{latest} Run analysis " <>
      "(start_analysis) on a clean tree at this commit, wait for spex to finish, then re-run."
  end

  defp latched_ids({:ok, items, _counts}), do: MapSet.new(items, & &1.criterion.id)
  defp latched_ids(_step), do: MapSet.new()

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

  defp plan_unpark(stories, criteria, qa_passed, newly_latched) do
    items =
      for story <- stories,
          story.ready_for_dev == false,
          MapSet.member?(qa_passed, story.id),
          live <- [criteria[story.id]],
          live != [],
          Enum.all?(live, &(&1.latched_at || MapSet.member?(newly_latched, &1.id))),
          do: %{story: story, before: "parked", after: "ready_for_dev"}

    {:ok, items, %{}}
  end

  defp released_ids({:ok, items, _counts}), do: MapSet.new(items, & &1.story.id)
  defp released_ids(_step), do: MapSet.new()
end
