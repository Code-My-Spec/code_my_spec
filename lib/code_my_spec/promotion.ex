defmodule CodeMySpec.Promotion do
  @moduledoc """
  Getting a working copy's finished work onto the checkout the local
  application runs from, so QA tests the code that was written.

  Two independent halves:

    * **A read model.** `running_copy_check/2` / `running_copy_verdicts/2`
      (in `Promotion.RunningCopy`) answer, per story, whether its files are on
      the running copy at the content its work produced — a question about
      state, so an agent working on the running copy satisfies it by arriving.

    * **An action.** `promote/3` gates, merges, reloads the app (or restarts
      it — `deployment_plan/2`), and reports what is being served.

  Not a deploy (`CodeMySpec.Deploys` is remote infrastructure). The merge is a
  `--ff-only` merge of the certified commit into the project's main copy, run
  through the harness; the deployment is the project's `just reload` / restart
  recipe, dispatched and not awaited.

  See knowledge/promotion, "Promotion".
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Analysis,
      CodeMySpec.BootVersion,
      CodeMySpec.Environments,
      CodeMySpec.Files,
      CodeMySpec.LandingHold,
      CodeMySpec.Problems,
      CodeMySpec.Promotion.RunningCopy,
      CodeMySpec.Qa,
      CodeMySpec.Repo,
      CodeMySpec.Stories,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils,
      CodeMySpec.Validation.Blocking,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  require Logger

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.BootVersion
  alias CodeMySpec.Files
  alias CodeMySpec.Problems.ProblemRepository
  alias CodeMySpec.Promotion.HandoffGate
  alias CodeMySpec.Promotion.Lock
  alias CodeMySpec.Promotion.Runner
  alias CodeMySpec.Qa
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation.Blocking
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.AppTransport
  alias CodeMySpec.WorkingCopies.WorkingCopy

  # ----------------------------------------------------------------- read model

  # The verdict lives in `Promotion.RunningCopy`, a leaf the requirement graph
  # reads too: the graph sits below promotion and must not call it.
  defdelegate running_copy_check(scope, entity), to: CodeMySpec.Promotion.RunningCopy
  defdelegate running_copy_verdicts(scope, stories), to: CodeMySpec.Promotion.RunningCopy

  # -------------------------------------------------------------- the promotion

  @doc """
  Gate, merge, restart, and report what the application is serving.

  Refuses rather than half-finishes, and every refusal names what the agent
  has to act on (the problem holding the gate, the conflicting file, the
  uncommitted work).

  One at a time, per project: `Lock.with_lock/2` holds the project's lock over
  gate and merge (the deployment is dispatched after). A second caller is
  refused, naming when the first started, never queued.

  `notify:` is the agent to tell how the deployment ended — confirmed or
  failed — after this has answered; the answer goes out when the merge lands,
  before anyone knows the app came back. `nil` (or omitted) means nobody is
  waiting and the log is the record.

  `story_number` names the story being promoted (main is the only target).
  That story alone is stamped promoted, and only if all of its spex pass on the
  promoting copy's certifying run; otherwise the promote is refused naming
  them. `nil` is non-story work (an issue fix): merged and deployed, nothing
  stamped.

  `restart: true` restarts instead of reloading; see `deployment_plan/2`.

  `verify_within:`/`verify_every:` (ms) bound how long a restart whose
  acknowledgement was lost is checked against what the app is serving.
  """
  @spec promote(Scope.t(), integer() | String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, map()}
  def promote(%Scope{} = scope, story_number, opts \\ []) do
    result =
      with :ok <-
             HandoffGate.check(
               scope.active_project_id,
               scope.active_working_copy_id
             ),
           {:ok, story} <- story_to_promote(scope, story_number),
           {:ok, running} <- running_copy(scope) do
        Lock.with_lock(running.project_id, fn -> promote_into(scope, running, story, opts) end)
        |> unlocked()
      end

    log_outcome(result)
  end

  @doc """
  Certify the scope's working copy for `story` at its HEAD, merging nothing: a
  clean tree, a clean run of every analyzer at that exact commit (`gate/3`,
  which starts any run that is missing and answers `{:pending, _}` until it
  lands), and the story's own spex green on it (`story_spex_pass/3`). With
  `main:`, the copy must also contain main — promotion's one extra check.

  The procedure the ready-for-QA gate and promotion share: ready-for-QA
  stamps the commit this answers for, promotion merges it. A
  promote at a commit already certified finds that commit's runs and starts
  none (`Analysis.answer_at_commit/3`).
  """
  @spec certify(Scope.t(), Stories.Story.t() | nil, keyword()) ::
          {:ok, %{head: String.t(), certified_by: [map()], precheck: map()}}
          | {:pending, map()}
          | {:error, map()}
  def certify(%Scope{} = scope, story, opts \\ []) do
    with {:ok, from} <- promoting_copy(scope, nil) do
      certify_copy(scope, from, story, Keyword.get(opts, :main), opts)
    end
  end

  defp certify_copy(scope, from, story, main, opts) do
    named = named_copy(from.id)

    with {:ok, pre} <-
           Runner.precheck(copy_environment(scope, from), from.root, from.id, main),
         {:ok, head} <- reported_head(pre, named),
         {:ok, swept} <- gate(scope, head, opts),
         :ok <- story_spex_pass(scope, story, named) do
      {:ok, %{head: head, certified_by: swept, precheck: pre}}
    end
  end

  @doc """
  The paths that differ between `from` and `to` on the scope's checkout — what
  certification reads to decide whether a QA pass carries forward. `nil` when
  they cannot be read, which carries nothing.
  """
  @spec changed_paths(Scope.t(), String.t() | nil, String.t()) :: [String.t()] | nil
  def changed_paths(_scope, nil, _to), do: nil

  def changed_paths(%Scope{} = scope, from, to) do
    with {:ok, copy} <- promoting_copy(scope, nil),
         {:ok, %{paths: paths}} when is_list(paths) <-
           Runner.changed(copy_environment(scope, copy), copy.root, from, to, copy.id) do
      paths
    else
      _ -> nil
    end
  end

  defp story_to_promote(_scope, nil), do: {:ok, nil}

  defp story_to_promote(scope, number) do
    case Stories.get_story_by_number(scope, number) do
      nil -> {:error, %{reason: "there is no story #{inspect(number)} in this project."}}
      story -> {:ok, story}
    end
  end

  # The log records what was decided independently of who received the answer.
  defp log_outcome(result) do
    Logger.info("[Promotion] #{outcome_label(result)}: #{outcome_text(result)}")
    result
  end

  defp unlocked({:error, {:already_promoting, started_at}}) do
    {:error,
     %{
       reason:
         "a promotion for this project is already in flight" <>
           since(started_at) <>
           ". Two at once decide the surviving build by timing rather than by either of you " <>
           "— promote again once it finishes.",
       already_promoting: true
     }}
  end

  defp unlocked(other), do: other

  defp since(%DateTime{} = started_at), do: ", since #{DateTime.to_iso8601(started_at)}"
  defp since(_), do: ""

  # Promoting from the running copy: nothing to merge, so this only restarts
  # the app. It must not refuse — an agent on the running copy with a dead app
  # has no other way out. No gate, since nothing crosses; the story's spex must
  # still pass on a spex run at main's HEAD (started here if missing), and it is
  # stamped with the version main already carries.
  defp promote_into(
         %Scope{active_working_copy_id: id} = scope,
         %WorkingCopy{id: id} = running,
         story,
         opts
       ) do
    named = named_copy(id)

    with {:ok, %{head: head, version: version}} <- current_of(scope, running, named),
         :ok <- runs_at(scope, ["spex"], head, named, opts),
         :ok <- story_spex_pass(scope, story, named),
         :ok <- record_landed_stories(scope, [{story, id, head}], version, head) do
      # Always a restart: nothing was merged, so there is no diff to judge a
      # reload by, and this path exists for an app that is down.
      plan = %{
        action: :restart,
        reason: "nothing was merged, so there is no change to judge a reload by"
      }

      # `deploy/4` always answers `{:error, %{reason: ...}}` (dispatched, not
      # awaited), so this wraps it as the success it is.
      {:error, reason} = deploy(scope, running, plan, Keyword.put(opts, :expect, %{to: head}))

      {:ok, %{restarted: running.root, serving: %{unconfirmed: reason}, deployment: plan}}
      |> with_story(story, version)
    else
      {:pending, pending} -> {:ok, %{pending: pending}}
      {:error, _} = error -> error
    end
  end

  # In order: the copy contains main, its tree is clean, every analyzer has a
  # clean run at its HEAD (started now, answered as pending, where missing),
  # and then exactly that commit is merged. No post-merge check: the merge is
  # `--ff-only`, so main's tree is byte-identical to the certified commit.
  # See knowledge/promotion, "Promotion".
  defp promote_into(%Scope{} = scope, running, story, opts) do
    with {:ok, from} <- promoting_copy(scope, running),
         named = named_copy(from.id),
         {:ok, main} <- main_head(scope, running, from),
         {:ok, %{head: head, certified_by: swept, precheck: %{branch: branch} = pre}} <-
           certify_copy(scope, from, story, main, opts),
         :ok <- head_unmoved(scope, from, head, named) do
      candidate = %{
        head: head,
        branch: branch,
        swept: swept,
        untracked: Map.get(pre, :untracked, [])
      }

      land_into(scope, running, from, candidate, [{story, from.id, head}], opts)
    else
      {:pending, pending} ->
        Logger.info(
          "[Promotion] pending for #{pending.working_copy}: analysis at #{pending.commit} " <>
            "(started #{inspect(pending.started)}, already running #{inspect(pending.running)})"
        )

        {:ok, %{pending: pending}}

      {:error, reason} = error ->
        refused(running, reason)
        error
    end
  end

  @doc """
  Land a commit the promotion queue has already certified, from its gate copy.

  The queue gates a batch of candidates in `from` (its gate checkout) at `head`
  and calls this on green: the same merge, submodule sync, stamping and one
  deployment a direct promotion runs after its gate, under the same lock, for
  every story in the batch. `stories` carries each story (or nil), its source
  working copy, and the candidate revision its QA must have reviewed.
  """
  @spec land(
          Scope.t(),
          WorkingCopy.t(),
          String.t(),
          [{Stories.Story.t() | nil, Ecto.UUID.t(), String.t()}],
          [map()],
          keyword()
        ) ::
          {:ok, map()} | {:error, map()}
  def land(%Scope{} = scope, %WorkingCopy{} = from, head, stories, swept, opts \\ []) do
    result =
      with {:ok, running} <- running_copy(scope) do
        candidate = %{
          head: head,
          branch: "the promotion batch at #{head}",
          swept: swept,
          untracked: []
        }

        Lock.with_lock(running.project_id, fn ->
          land_into(scope, running, from, candidate, stories, opts)
        end)
        |> unlocked()
      end

    log_outcome(result)
  end

  defp land_into(scope, running, from, candidate, stories, opts) do
    %{head: head, branch: branch, swept: swept, untracked: untracked} = candidate
    environment = copy_environment(scope, from)

    with :ok <- story_reviews_current(scope, stories),
         {:ok, merge_result} <- Runner.merge(environment, running.root, head, from.id),
         # Before stamping or restarting: a refusal here has rolled the merge back.
         {:ok, _} <-
           Runner.sync_submodule(environment, running.root, from.root, merge_result, from.id),
         :ok <-
           record_landed_stories(
             scope,
             stories,
             Map.get(merge_result, :stamp_version),
             Map.get(merge_result, :after)
           ) do
      version = Map.get(merge_result, :version)
      stamp_version = Map.get(merge_result, :stamp_version)

      Logger.info(
        "[Promotion] merged #{branch} at #{head} into #{running.root} " <>
          "(#{Map.get(merge_result, :before) || "?"} -> #{Map.get(merge_result, :after) || "?"}), " <>
          "version #{version || "none"}, stamping #{stamp_version || "none"}, " <>
          "certified by #{describe_certifications(swept)}, dispatching deployment"
      )

      version_error = Map.get(merge_result, :version_error)

      if version_error,
        do:
          Logger.error(
            "[Promotion] merged, but the version tag was NOT created: #{version_error}"
          )

      # Stamp `stamp_version`, not `version`: a no-op merge originates no
      # version and still has a story to stamp.
      # See knowledge/promotion, "Versions".

      # `head` and `after` are the same commit (a promotion tags, it does not
      # commit a bump); both are read so either result shape works.
      expect = %{
        from: Map.get(merge_result, :before),
        to: Map.get(merge_result, :head) || Map.get(merge_result, :after)
      }

      plan = deployment_plan(Map.get(merge_result, :changed), reload_opts(running, opts))

      Logger.info("[Promotion] #{plan.action} #{running.root}: #{plan.reason}")

      scope
      |> deploy(running, plan, Keyword.put(opts, :expect, expect))
      |> merged(branch, running, swept, untracked, version)
      |> with_deployment(plan)
      |> with_stories(stories, stamp_version)
      |> with_version_error(version_error)
    else
      {:error, reason} = error ->
        refused(running, reason)
        error
    end
  end

  # Names the copy the refusal is about (`:working_copy`), falling back to the
  # merge target only for refusals from before the gate runs.
  defp refused(running, %{landed: true} = reason) do
    Logger.error(
      "[Promotion] landed into #{running.root}, but completion is held: #{reason.reason}"
    )
  end

  defp refused(running, reason) do
    named = Map.get(reason, :working_copy, running.root)

    Logger.warning(
      "[Promotion] refused for #{named}: #{Map.get(reason, :reason, inspect(reason))}"
    )
  end

  # `deploy/4` always answers `{:error, %{reason: ...}}`. A lost or
  # not-awaited acknowledgement is reported as merged, restart unconfirmed —
  # never as failure: the merge happened, and an agent told otherwise promotes
  # again, restarting the shared dev server for every copy on the box.
  defp merged({:error, reason}, branch, running, swept, untracked, version) do
    reason
    |> restart_acknowledgement_lost?()
    |> unconfirmed(reason, branch, running, swept, untracked, version)
  end

  defp unconfirmed(true, reason, branch, running, swept, untracked, version) do
    {:ok,
     %{
       merged: branch,
       into: running.root,
       version: version,
       serving: %{revision: nil, unconfirmed: reason},
       swept: swept,
       untracked: untracked
     }}
  end

  defp unconfirmed(false, reason, _branch, _running, _swept, _untracked, _version),
    do: {:error, reason}

  defp with_deployment({:ok, report}, plan), do: {:ok, Map.put(report, :deployment, plan)}
  defp with_deployment(error, _plan), do: error

  # One story keeps the shape a direct promotion has always answered with; a
  # batch also lists every story it carried.
  defp with_stories(result, [{story, _copy_id, _revision}], version),
    do: with_story(result, story, version)

  defp with_stories({:ok, report}, stories, version) do
    numbers = for {%{number: number}, _copy_id, _revision} <- stories, do: number
    {:ok, Map.put(report, :stories, Enum.map(numbers, &%{number: &1, version: version}))}
  end

  defp with_stories(error, _stories, _version), do: error

  defp with_story(result, nil, _version), do: result

  defp with_story({:ok, report}, story, version),
    do: {:ok, Map.put(report, :story, %{number: story.number, version: version})}

  defp with_story(error, _story, _version), do: error

  defp with_version_error({:ok, report}, reason) when is_binary(reason),
    do: {:ok, Map.put(report, :version_error, reason)}

  defp with_version_error(result, _reason), do: result

  # Only the landed stories are stamped: a project-wide sweep would stamp
  # stories whose code sits unmerged on another copy.
  @doc """
  What a landing does for the stories in it, in one transaction: each story's
  reviewed QA issues are completed and it is stamped promoted at `version` and
  `commit`; then its team's freedom is announced (`[:promotion, :team_free]`,
  the same offer an issue finishing through QA sends). Also for a candidate
  main already contains (`PromotionQueue`), which lands as it is.

  A write failure answers `{:error, %{landed: true, assignment_held: true}}`:
  the merge on disk is real, the story-side completion is not.
  """
  @spec record_landed_stories(
          Scope.t(),
          [{Stories.Story.t() | nil, Ecto.UUID.t(), String.t()}],
          String.t() | nil,
          String.t() | nil
        ) :: :ok | {:error, map()}
  def record_landed_stories(scope, stories, version, commit) do
    result =
      Repo.transaction(fn ->
        for {story, copy_id, expected_revision} <- stories, not is_nil(story) do
          complete_and_stamp_story(scope, story, version, commit, copy_id, expected_revision)
        end
      end)

    case result do
      {:ok, _} ->
        Enum.each(stories, fn {story, copy_id, _revision} ->
          notify_team_free(scope, copy_id, story)
        end)

        :ok

      {:error, reason} ->
        {:error,
         %{
           landed: true,
           assignment_held: true,
           landed_commit: commit,
           reason:
             "Code landed, but story work could not be completed: #{inspect(reason)}. Assignment remains held."
         }}
    end
  end

  defp complete_and_stamp_story(scope, story, version, commit, copy_id, expected_revision) do
    case Qa.complete_reviewed_story_issues(scope, story, commit, expected_revision) do
      {:ok, _issues} -> stamp_promoted_story(scope, story, version, commit, copy_id)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def story_reviews_current(scope, stories) do
    case Enum.find(stories, fn {story, _copy, expected_revision} ->
           not is_nil(story) and not Qa.story_review_current?(scope, story.id, expected_revision)
         end) do
      nil ->
        :ok

      {story, _, expected_revision} ->
        {:error,
         %{
           reason:
             "Story #{story.number} needs QA of its current submitted work at candidate #{expected_revision} before promotion.",
           qa_not_current: true
         }}
    end
  end

  defp notify_team_free(_scope, _copy_id, nil), do: :ok

  defp notify_team_free(scope, copy_id, story),
    do:
      :telemetry.execute([:code_my_spec, :promotion, :team_free], %{}, %{
        scope: scope,
        working_copy_id: copy_id,
        story: story
      })

  defp stamp_promoted_story(_scope, nil, _version, _commit, _copy_id), do: :ok

  defp stamp_promoted_story(scope, story, version, commit, copy_id) do
    opts = [at: DateTime.utc_now(), commit: commit, working_copy_id: copy_id]

    case Stories.mark_story_promoted(scope, story, version, opts) do
      {:ok, _story} ->
        :ok

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # The story's spex are found by `files.story_id` and by the criterion numbers
  # they name, never by parsing directory names. A story with no linked spex
  # refuses: an empty list is not a pass.
  @doc """
  Whether `story`'s own spex all pass on the scope's copy's certifying spex run
  — the check a promotion makes before latching a story. `:ok`, or
  `{:error, %{reason:, failing_spex:}}`. The promotion queue asks it of each
  story in a batch: the findings are the gate copy's run, and `files_scope`
  (the candidate's own copy) says which files are the story's spex — the gate
  copy's file rows may not have caught up with the checkout a batch just made.
  """
  @spec story_spex_check(Scope.t(), Stories.Story.t() | nil, Scope.t() | nil) ::
          :ok | {:error, map()}
  def story_spex_check(%Scope{active_working_copy_id: id} = scope, story, files_scope \\ nil),
    do: story_spex_pass(scope, story, named_copy(id), files_scope)

  # `files_scope` is the copy whose file rows say which spex are the story's —
  # the promotion queue's candidate, when the run being read is the gate copy's.
  defp story_spex_pass(scope, story, named, files_scope \\ nil)

  defp story_spex_pass(_scope, nil, _named, _files_scope), do: :ok

  # Every red spex on the story refuses it.
  defp story_spex_pass(scope, story, named, files_scope) do
    files_scope = files_scope || scope
    numbers = scope |> AcceptanceCriteria.list_story_criteria(story.id) |> MapSet.new(& &1.number)

    file_paths =
      files_scope
      |> Files.list_story_files(story.id)
      |> Enum.filter(&(&1.role == :bdd_spec))
      |> MapSet.new(& &1.path)

    paths =
      for {path, number} <- Files.bdd_spec_criterion_numbers(files_scope),
          MapSet.member?(numbers, number),
          into: file_paths,
          do: path

    failing =
      scope
      |> ProblemRepository.list_project_problems(source: "spex")
      |> Enum.filter(&MapSet.member?(paths, &1.file_path))

    spex_verdict(story, file_paths, failing, named)
  end

  # The running copy's HEAD, which its spex run has to answer for, and the
  # version to stamp. Without a HEAD there is no run to read, so it refuses.
  defp current_of(scope, %WorkingCopy{root: root, id: id}, named) do
    case Runner.current(copy_environment(scope, id), root, id) do
      {:ok, %{head: head} = current} when is_binary(head) ->
        {:ok, %{head: head, version: Map.get(current, :version)}}

      other ->
        {:error,
         %{reason: "could not read #{root}'s HEAD: #{inspect(other)}", working_copy: named}}
    end
  end

  # Runner disk work belongs to the harness for the selected working copy.
  # `main_head/3` and `land_into/6` deliberately pair `from`'s harness with
  # the running copy's root: the harness is the transport, the root is the
  # payload being operated on.
  defp copy_environment(scope, %WorkingCopy{id: id}), do: copy_environment(scope, id)

  defp copy_environment(scope, id),
    do: WorkingCopies.environment(%{scope | active_working_copy_id: id})

  # Main's HEAD, which the promoting copy must contain. Asked through the
  # promoting copy's harness, the one the merge runs through.
  defp main_head(scope, running, from) do
    case Runner.current(copy_environment(scope, from), running.root, from.id) do
      {:ok, %{head: head}} when is_binary(head) ->
        {:ok, head}

      other ->
        {:error, %{reason: "could not read main's HEAD at #{running.root}: #{inspect(other)}"}}
    end
  end

  # A harness older than commit-keyed promotion answers the precheck without a
  # HEAD (and without checking main). Its runs carry no commits either, so
  # nothing it analyses could ever qualify: refused by name rather than left
  # pending forever.
  defp reported_head(%{head: head}, _named) when is_binary(head), do: {:ok, head}

  defp reported_head(_pre, named) do
    {:error,
     %{
       reason:
         "the harness serving #{named} did not report its HEAD, so it predates " <>
           "commit-keyed promotion and its analysis runs record no commit. Restart " <>
           "it on the current version, then promote again.",
       working_copy: named
     }}
  end

  # The certified commit is what merges. If the copy moved since, the commit
  # at its tip is not the one that was certified.
  defp head_unmoved(scope, from, head, named) do
    case Runner.current(copy_environment(scope, from), from.root, from.id) do
      {:ok, %{head: ^head}} ->
        :ok

      {:ok, %{head: moved}} ->
        {:error,
         %{
           reason:
             "#{named} moved from #{head} to #{moved} while this promotion checked it, " <>
               "so nothing was merged. Promote again.",
           working_copy: named
         }}

      {:error, reason} ->
        {:error,
         %{reason: "could not re-read #{named}'s HEAD: #{inspect(reason)}", working_copy: named}}
    end
  end

  defp spex_verdict(story, paths, [], named) do
    if MapSet.size(paths) == 0 do
      {:error,
       %{
         reason:
           "story #{story.number} has no spex linked on #{named}, so nothing says " <>
             "its spex pass. Write them (or sync so they link), then try again.",
         working_copy: named
       }}
    else
      :ok
    end
  end

  defp spex_verdict(story, _paths, failing, named) do
    {:error,
     %{
       reason:
         "story #{story.number}'s spex are not all passing on #{named}'s certifying " <>
           "spex run, so it is not promoted:\n" <>
           describe("spex", failing) <>
           "\n\nFix them, let spex run, then try again.",
       failing_spex: failing |> Enum.map(& &1.file_path) |> Enum.uniq(),
       working_copy: named
     }}
  end

  @doc """
  Whether a restart failure is the expected shape of a restart that worked
  (or of one dispatched and not awaited).

  `draining` / `not_connected` elsewhere mean "the server went away"; for a
  restart, the server going away is the operation succeeding. Public so the
  rule is written once rather than re-derived by each caller.
  """
  @spec restart_acknowledgement_lost?(term()) :: boolean()
  def restart_acknowledgement_lost?(%{reason: reason}) when is_binary(reason) do
    String.contains?(reason, "promotion_restart") or
      String.contains?(reason, "not_connected") or
      String.contains?(reason, "draining") or
      String.contains?(reason, "not awaited")
  end

  def restart_acknowledgement_lost?(_), do: false

  # `promote/3` is synchronous on purpose: nothing before the dispatched
  # deployment is long-running. See knowledge/promotion, "Promotion".

  defp outcome_label({:ok, %{pending: _}}), do: "pending"
  defp outcome_label({:ok, _}), do: "promoted"
  defp outcome_label({:error, %{landed: true}}), do: "landed; completion held"
  defp outcome_label({:error, _}), do: "refused"
  defp outcome_label(_other), do: "returned something unexpected"

  @doc """
  What a promotion's result says, in the words the caller reads. "Merged,
  deployment unconfirmed" is the normal success and is worded as such.
  """
  @spec outcome_text(term()) :: String.t()
  def outcome_text(result), do: base_outcome_text(result) <> version_note(result)

  # A merge whose tag failed is still a merge, so the note rides on whatever
  # the outcome says rather than replacing it.
  defp version_note({:ok, %{version_error: reason}}) when is_binary(reason) do
    "\n\nThe version tag was NOT created: #{reason}. The merge landed and nothing " <>
      "else is affected; tag the promoted commit by hand once the cause is fixed."
  end

  defp version_note(_result), do: ""

  defp base_outcome_text({:ok, %{merged: branch, serving: %{unconfirmed: _}} = report}) do
    {action, why} = deployment_words(report)

    "Your promotion merged #{branch} onto the running dev copy. The application " <>
      "#{action} (#{why}) is running now in the background, not waited on — that is by " <>
      "design, so a promotion answers in seconds regardless of how long the " <>
      "#{action} takes or whether it is this checkout's own process restarting. " <>
      "QA on these stories can start against the merge already; check what is " <>
      "serving in a moment if you want the restart confirmed:\n\n" <>
      "    git merge-base --is-ancestor HEAD $(curl -s localhost:4004/health " <>
      "| python3 -c 'import json,sys; print(json.load(sys.stdin)[\"build\"])')\n\n" <>
      "Exit 0 means it has landed. Do not promote again just to check — that " <>
      "restarts the shared dev server for every working copy on this machine."
  end

  # Promoting from the running copy is a restart and nothing else, so it has
  # no branch to name — the same "dispatched, not awaited" outcome as a
  # merge, worded for the case where nothing was merged.
  defp base_outcome_text({:ok, %{restarted: root, serving: %{unconfirmed: _}}}) do
    "Your promotion finished. There was nothing to merge — you are working on " <>
      "the running copy — so the application at #{root} is restarting now in " <>
      "the background, not waited on. Do not promote again just to check; ask " <>
      "what is serving instead."
  end

  defp base_outcome_text({:ok, %{pending: pending}}), do: pending_text(pending)

  defp base_outcome_text({:error, %{landed: true, reason: reason}}),
    do:
      "The code landed on main, but story completion is held. #{reason} Do not re-merge this candidate."

  defp base_outcome_text({:error, %{reason: reason}}),
    do: "Your promotion did not go through. #{reason}"

  defp base_outcome_text(other),
    do: "Your promotion returned something unexpected: #{inspect(other)}"

  @doc "Whether a promote reloads or restarts, and why, in words."
  @spec deployment_words(map()) :: {String.t(), String.t()}
  def deployment_words(%{deployment: %{action: action, reason: reason}}),
    do: {to_string(action), reason}

  def deployment_words(_report), do: {"restart", "no deployment plan was recorded"}

  @doc """
  What a pending promotion says: analysis is running at the commit it will
  certify, nothing was merged, and the result arrives when it lands.
  """
  @spec pending_text(map()) :: String.t()
  def pending_text(%{commit: commit} = pending) do
    sources = Enum.join(Map.get(pending, :started, []) ++ Map.get(pending, :running, []), ", ")

    "Analysis running at #{commit} (#{sources}); you'll get the result when it " <>
      "lands. Nothing was merged. If it is clean, promote again and that commit " <>
      "merges; if not, fix what it finds, commit, and promote again."
  end

  defp running_copy(%Scope{} = scope) do
    scope
    |> WorkingCopies.main()
    |> case do
      %WorkingCopy{root: root} = copy when is_binary(root) ->
        {:ok, copy}

      %WorkingCopy{} ->
        {:error,
         %{
           reason:
             "this project's main copy has not reported where it is, so there " <>
               "is nowhere to merge to."
         }}

      nil ->
        {:error,
         %{
           reason:
             "this project has no main working copy, so a promotion has no " <>
               "target. Designate one on the working copies page."
         }}
    end
  end

  defp promoting_copy(%Scope{active_working_copy_id: id}, _running) when is_binary(id) do
    case WorkingCopies.fetch(id) do
      {:ok, %WorkingCopy{root: root} = copy} when is_binary(root) -> {:ok, copy}
      _ -> {:error, %{reason: "this checkout has not reported where it is."}}
    end
  end

  defp promoting_copy(%Scope{}, _running),
    do: {:error, %{reason: "no working copy on this scope; nothing to promote."}}

  # Keyed on the commit, never on fingerprints. Logged first, so a gate
  # reading the wrong copy is diagnosable from this line alone.
  # See knowledge/promotion, "The gate".
  @doc """
  Whether the promoting copy (`scope.active_working_copy_id`) may merge `head`.

  Every analyzer needs a run at `head` (`Analysis.answer_at_commit/3`). The
  problems those runs recorded must be zero (every red spex refuses). Compiler,
  credo and exunit findings refuse at
  `:error` or `:warning`; `:info` (low-priority credo) is advisory. A spex
  finding with no location is advisory (`Blocking.enforceable/2`).

  A source with no run at `head` has one started (`requested_by` the agent in
  `opts[:notify]`) unless one is already running there, and the answer is
  `{:pending, %{commit:, started:, running:}}`. A blocking problem from a run
  that is at `head` refuses regardless: no pending run can clear it.

  `{:ok, certified_by}`, `{:pending, map}` or `{:error, %{reason: ...}}`.
  """
  @spec gate(Scope.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:pending, map()} | {:error, map()}
  def gate(
        %Scope{active_working_copy_id: working_copy_id, active_project_id: project_id} = scope,
        head,
        opts \\ []
      ) do
    Logger.info(
      "[Promotion] gate for project #{project_id}: active_working_copy_id=#{working_copy_id} " <>
        "at #{head}"
    )

    with {:ok, scope, named} <- gate_copy(scope, working_copy_id) do
      # Every source, whatever the project's config: config decides what the
      # stop hook sweeps, never what promote demands.
      {answered, missing} = answers_at(scope, Run.sources(), head)

      case blocking_problems(scope, Map.keys(answered)) do
        [] -> certify(scope, answered, missing, head, named, opts)
        problems -> gate_result(problems, named)
      end
      |> log_gate(working_copy_id, head)
    end
  end

  # No copy on the scope refuses. The problem read would otherwise fall back to
  # the project's default copy and judge a checkout the caller never named.
  defp gate_copy(scope, working_copy_id) when is_binary(working_copy_id) do
    {:ok, scope, named_copy(working_copy_id)}
  end

  defp gate_copy(_scope, nil) do
    {:error,
     %{
       reason:
         "no working copy on this scope, so there is nothing to gate. A promotion " <>
           "judges one checkout's commit; name the working copy it is yours to " <>
           "promote from.",
       working_copy: nil
     }}
  end

  # The gate's answer, beside the line that says it was asked: a gate that was
  # asked and never answered is told apart from one that was never asked.
  defp log_gate(result, working_copy_id, head) do
    Logger.info(
      "[Promotion] gate for #{working_copy_id} at #{head} answered #{gate_outcome(result)}"
    )

    result
  end

  defp gate_outcome({:ok, _certified}), do: "green"
  defp gate_outcome({:pending, pending}), do: "pending, started #{inspect(pending[:started])}"
  defp gate_outcome({:error, refusal}), do: "refused (#{inspect(refusal[:counts])})"

  @doc """
  Whether the scope's copy is already certified at `head`: every analyzer has a
  run that answers for it there, and none of them found anything blocking. A
  read — nothing is started.
  """
  @spec certified_at?(Scope.t(), String.t()) :: boolean()
  def certified_at?(%Scope{} = scope, head) do
    case answers_at(scope, Run.sources(), head) do
      {answered, []} -> blocking_problems(scope, Map.keys(answered)) == []
      {_answered, _missing} -> false
    end
  end

  @doc """
  What the scope's copy's own analysis at `head` already says blocks it: `:ok`,
  or the gate's refusal. A read — it starts nothing, and a source with no answer
  at `head` is not a refusal.
  """
  @spec red_at(Scope.t(), String.t()) :: :ok | {:error, map()}
  def red_at(%Scope{active_working_copy_id: id} = scope, head) do
    case blocking_problems_at(scope, head) do
      [] -> :ok
      problems -> gate_result(problems, named_copy(id))
    end
  end

  @doc """
  The problems `gate/3` judges at `head`: those of the sources whose latest
  run on the scope's copy is at `head`.

  Problems are kept per copy, not per commit, so a source not yet answered at
  `head` still holds its previous run's problems — another commit's. A red
  batch is triaged on exactly what refused it, never on those.
  """
  @spec blocking_problems_at(Scope.t(), String.t()) :: [struct()]
  def blocking_problems_at(%Scope{} = scope, head) do
    {answered, _missing} = answers_at(scope, Run.sources(), head)
    blocking_problems(scope, Map.keys(answered))
  end

  defp certify(_scope, answered, [], _head, _named, _opts), do: {:ok, certified_by(answered)}

  defp certify(scope, _answered, missing, head, named, opts),
    do: start_missing(scope, missing, head, named, opts)

  # The running-copy path's check: `sources` answered at `head`, or started.
  defp runs_at(scope, sources, head, named, opts) do
    case answers_at(scope, sources, head) do
      {_answered, []} -> :ok
      {_answered, missing} -> start_missing(scope, missing, head, named, opts)
    end
  end

  defp answers_at(scope, sources, head) do
    runs = Map.new(sources, &{&1, gate_answer(&1, Analysis.answer_at_commit(scope, &1, head))})
    {answered, missing} = Enum.split_with(runs, fn {_source, run} -> run end)
    {Map.new(answered), Enum.map(missing, &elem(&1, 0))}
  end

  # One run per missing source, unless one is already running at `head` (a
  # second would certify the same commit twice). On a run someone else started,
  # or one a start joined, the agent in `opts[:notify]` is added as a waiter.
  defp start_missing(scope, missing, head, named, opts) do
    agent_id = Keyword.get(opts, :notify)
    {running, to_start} = Enum.split_with(missing, &running_at?(scope, &1, head, agent_id))
    requested_by = requested_by(agent_id)

    {started, failed} =
      to_start
      |> Enum.map(&{&1, Analysis.start_run(scope, &1, gate_args(&1), requested_by: requested_by)})
      |> Enum.split_with(&match?({_source, {:ok, _, _}}, &1))

    for {source, {:ok, :joined, _id}} <- started, do: running_at?(scope, source, head, agent_id)

    pending(Enum.map(started, &elem(&1, 0)), running, failed, head, named)
  end

  defp running_at?(scope, source, head, nil), do: Analysis.running_at_commit?(scope, source, head)

  defp running_at?(scope, source, head, agent_id),
    do: Analysis.wait_on_running_at_commit(scope, source, head, agent_id)

  # The gate's compiler run is forced: an incremental compile reports only what
  # it recompiled, and another analyzer holding the build lock had already
  # compiled a boundary violation, so the compiler saw nothing and passed it.
  defp gate_args("compiler"), do: ["--force"]
  defp gate_args(_source), do: []

  defp gate_answer("compiler", %Run{args: %{"args" => args}} = run) when is_list(args),
    do: if("--force" in args, do: run)

  defp gate_answer("compiler", _run), do: nil
  defp gate_answer(_source, run), do: run

  defp requested_by(nil), do: %{kind: "promotion"}
  defp requested_by(agent_id), do: %{kind: "promotion", agent_id: agent_id}

  defp pending(started, running, [], head, named),
    do: {:pending, %{commit: head, started: started, running: running, working_copy: named}}

  defp pending(_started, _running, failed, head, named) do
    {:error,
     %{
       reason:
         "#{named} has no clean analysis run at #{head} for " <>
           Enum.map_join(failed, ", ", fn {source, error} ->
             "#{source} (could not start one: #{inspect(error)})"
           end) <> ". Nothing was merged.",
       working_copy: named
     }}
  end

  # Every refusal names the copy its findings belong to, which may not be the
  # caller's own.
  defp named_copy(nil), do: "no working copy on this scope"

  defp named_copy(working_copy_id) do
    case WorkingCopies.fetch(working_copy_id) do
      {:ok, %WorkingCopy{root: root}} when is_binary(root) -> "#{working_copy_id} (#{root})"
      _ -> working_copy_id
    end
  end

  # What this promote leaned on to call the copy clean: the run per source at
  # the certified commit, carried on `swept` so two promotes reading the same
  # runs are visibly the same verdict.
  defp certified_by(answered) do
    for source <- Run.sources(), %Run{} = run <- [answered[source]] do
      %{source: source, finished_at: run.finished_at, commit: run.completed_commit}
    end
  end

  # The log line's rendering of `certified_by/1`.
  defp describe_certifications(certifications) do
    certifications
    |> Enum.map_join(", ", fn
      %{source: source, finished_at: nil} ->
        "#{source} (no run on file)"

      %{source: source, finished_at: finished_at} ->
        "#{source} @ #{DateTime.to_iso8601(finished_at)}"
    end)
  end

  @doc """
  Every problem recorded on the scope's copy that the gate would block on, from
  every source's latest run wherever it ran: the story_promoted task lists
  these at start, so the agent fixes what completing it would refuse.
  """
  @spec blocking_problems(Scope.t()) :: [struct()]
  def blocking_problems(%Scope{} = scope), do: blocking_problems(scope, Run.sources())

  @doc "`problems` by source, a few lines each, as the gate's refusal lists them."
  @spec describe_problems([struct()]) :: String.t()
  def describe_problems(problems) do
    by_source = Enum.group_by(problems, & &1.source)

    Run.sources()
    |> Enum.filter(&Map.has_key?(by_source, &1))
    |> Enum.map_join("\n\n", &describe(&1, by_source[&1]))
  end

  defp gate_result(problems, named) do
    by_source = Enum.group_by(problems, & &1.source)
    sources = Enum.filter(Run.sources(), &Map.has_key?(by_source, &1))
    counts = Enum.map_join(sources, ", ", &"#{length(by_source[&1])} #{&1}")

    {:error,
     %{
       reason:
         "#{named} is carrying #{length(problems)} problem(s) (#{counts}), so it " <>
           "promotes nothing.\n\n" <>
           describe_problems(problems) <>
           "\n\nA promotion needs zero compiler, credo and exunit errors and " <>
           "warnings, and no red spex. Fix these on " <>
           "#{named}, commit, and promote again." <>
           "\n\nIf #{named} is not this session's own working copy, the gate " <>
           "resolved to a different checkout than the one calling it — fix on " <>
           "that copy, or say so if this looks wrong; a sweep run from here " <>
           "will not touch problems recorded against a different working copy.",
       problems: Enum.map(problems, &problem_key/1),
       counts: Map.new(by_source, fn {source, of_source} -> {source, length(of_source)} end),
       working_copy: named
     }}
  end

  # Only sources whose latest run is at the certified commit: another commit's
  # problems describe a different tree. Credo and compiler block whatever the
  # stop hook's mode says (a warning let onto main blocks every copy's
  # promote); exunit and spex go through `Blocking.enforceable/2`. Whether an
  # advisory finding can block at all is `Blocking.blockable/2`'s answer.
  @always_block ~w(credo compiler)

  defp blocking_problems(%Scope{} = scope, sources) do
    strict = problems_of(scope, Enum.filter(sources, &(&1 in @always_block)))

    scope
    |> problems_of(Enum.reject(sources, &(&1 in @always_block)))
    |> then(&Blocking.enforceable(scope, &1))
    |> Kernel.++(strict)
    |> then(&Blocking.blockable(scope, &1))
  end

  defp problems_of(_scope, []), do: []

  defp problems_of(scope, sources),
    do: ProblemRepository.list_project_problems(scope, sources: sources)

  @doc """
  Whether a promote reloads the running app or restarts it, and why.

  Reload by default: a restart of :4000 kills every in-flight agent turn and
  analysis run on the box. Restart when `changed` (the merge's paths) touches
  anything in `BootVersion.restart_paths/0`, when it is `nil` (not readable,
  so not judged), when the harness cannot reload (`reload_supported: false`),
  or when the caller asks (`restart: true`). A reload that fails restarts
  inside the same deployment.
  """
  @spec deployment_plan([String.t()] | nil, keyword()) ::
          %{action: :reload | :restart, reason: String.t()}
  def deployment_plan(changed, opts \\ []) do
    cond do
      Keyword.get(opts, :restart) == true ->
        %{action: :restart, reason: "a restart was asked for"}

      Keyword.get(opts, :reload_supported, true) == false ->
        %{action: :restart, reason: "the harness serving the app predates reloads"}

      not is_list(changed) ->
        %{action: :restart, reason: "the merge did not report which files it changed"}

      (touched = BootVersion.needs_restart(changed)) != [] ->
        %{
          action: :restart,
          reason: "the change touches #{describe_paths(touched)}, which a reload cannot pick up"
        }

      true ->
        %{action: :reload, reason: "nothing in the change needs a restart"}
    end
  end

  defp describe_paths(paths) do
    shown = Enum.take(paths, 3) |> Enum.join(", ")
    if length(paths) > 3, do: "#{shown} and #{length(paths) - 3} more", else: shown
  end

  defp reload_opts(running, opts),
    do: Keyword.put(opts, :reload_supported, AppTransport.reload_supported?(running.id))

  # Dispatched, never awaited: the restart may kill this very BEAM before it
  # could answer. `merged/6` reads the result as "merged, restart unconfirmed".
  # `preview_status` is claimed "serving" here, before any confirmation, so the
  # next gate read does not see a stale `down` and loop the agent.
  # See knowledge/promotion, "Deployment".
  defp deploy(%Scope{} = scope, %WorkingCopy{root: root} = running, plan, opts) do
    dispatch_deployment(scope, root, running.id, plan, opts)
    {:ok, _} = WorkingCopies.record_preview_status(running, "serving")
    {:error, %{reason: deployment_dispatched_reason(plan)}}
  end

  # Detached: this process may not exist by the time a restart returns. The
  # deployment's outcome is resolved, logged and told to the agent here — the
  # one place it ever is.
  defp dispatch_deployment(scope, root, working_copy_id, plan, opts) do
    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        {done, outcome} = deploy_now(plan, scope, root, working_copy_id, opts)

        outcome
        |> log_restart_outcome(root, done)
        |> tell_the_agent(scope, root, done, Keyword.get(opts, :notify))
      end)

    :ok
  end

  # `done` names what actually ran, for the log and the agent: the plan, or
  # the restart a reload fell back to.
  defp deploy_now(%{action: :restart}, scope, root, working_copy_id, opts) do
    outcome =
      scope
      |> Runner.restart(root, working_copy_id)
      |> classify_restart()
      |> verify_unconfirmed(working_copy_id, opts)

    {"restart", outcome}
  end

  defp deploy_now(%{action: :reload}, scope, root, working_copy_id, opts) do
    scope
    |> Runner.reload(root, working_copy_id)
    |> reloaded(scope, root, working_copy_id, opts)
  end

  # The far side restarted instead (app not running, no `reload` recipe).
  defp reloaded({:ok, %{action: "restarted"} = done}, _scope, _root, _id, _opts),
    do:
      {"restart (#{done.action_reason || "the harness restarted instead"})",
       {:confirmed, done.revision}}

  defp reloaded({:ok, %{revision: revision}}, _scope, _root, _id, _opts),
    do: {"reload", {:confirmed, revision}}

  # A channel lost mid-reload may have taken a reload that worked with it —
  # :4000's own reloader swaps the channel's modules. Asked what is serving
  # before restarting over it.
  defp reloaded({:error, %{reason: reason} = error}, scope, root, working_copy_id, opts) do
    with true <- restart_acknowledgement_lost?(error),
         {:confirmed, _} = confirmed <-
           verify_unconfirmed({:unconfirmed, reason}, working_copy_id, opts) do
      {"reload", confirmed}
    else
      _ ->
        Logger.warning("[Promotion] reload of #{root} failed (#{reason}); restarting instead")
        {"restart", outcome} = deploy_now(%{action: :restart}, scope, root, working_copy_id, opts)
        {"restart after a failed reload (#{reason})", outcome}
    end
  end

  # One verdict, read by both the log and the agent message, so they cannot
  # disagree. See knowledge/promotion, "Lessons".
  defp classify_restart({:ok, %{revision: revision}}), do: {:confirmed, revision}

  defp classify_restart({:error, %{reason: reason} = error}) do
    if restart_acknowledgement_lost?(error),
      do: {:unconfirmed, reason},
      else: {:failed, reason}
  end

  defp classify_restart(other), do: {:unexpected, other}

  # A lost acknowledgement is settled by asking the app what it serves
  # (`AppTransport`) until it reports the merged commit or the bound runs out.
  # Only an app answering on the wrong commit is a failure; one that never
  # answered stays unconfirmed.
  @verify_every 2_000

  defp verify_unconfirmed({:unconfirmed, _reason}, working_copy_id, opts) do
    expect = Keyword.get(opts, :expect, %{})
    every = Keyword.get(opts, :verify_every, @verify_every)

    within =
      Keyword.get_lazy(opts, :verify_within, fn ->
        Application.get_env(:code_my_spec, :promotion_verify_within, 120_000)
      end)

    deadline = System.monotonic_time(:millisecond) + within

    await_serving(working_copy_id, Map.get(expect, :to), every, deadline, :unanswered)
  end

  defp verify_unconfirmed(outcome, _working_copy_id, _opts), do: outcome

  # `seen` is the last commit the app reported, or `:unanswered`.
  defp await_serving(working_copy_id, expected, every, deadline, seen) do
    remaining = deadline - System.monotonic_time(:millisecond)

    working_copy_id
    |> AppTransport.ensure_app_running(max(remaining, every))
    |> serving_commit()
    |> case do
      {"serving", commit} when expected in [nil, commit] ->
        {:confirmed, commit}

      {_status, commit} when is_binary(commit) ->
        retry_serving(working_copy_id, expected, every, deadline, commit)

      _unreachable_or_down ->
        retry_serving(working_copy_id, expected, every, deadline, seen)
    end
  end

  # What the app serves, not what it launched from: a reload moves the first
  # and leaves the second, and reading the launch commit called a reload that
  # worked "still on <old>".
  defp serving_commit({:ok, %{status: status} = info}),
    do: {status, Map.get(info, :serving_commit) || Map.get(info, :commit)}

  defp serving_commit(_other), do: :unanswered

  defp retry_serving(working_copy_id, expected, every, deadline, seen) do
    if System.monotonic_time(:millisecond) + every < deadline do
      Process.sleep(every)
      await_serving(working_copy_id, expected, every, deadline, seen)
    else
      settle_unverified(seen)
    end
  end

  defp settle_unverified(:unanswered),
    do: {:unconfirmed, "the app never answered, so the restart could not be verified"}

  defp settle_unverified(seen), do: {:failed, "restart failed: still on #{seen}"}

  defp log_restart_outcome({:confirmed, revision} = outcome, root, done) do
    Logger.info(
      "[Promotion] #{done} confirmed for #{root}, now serving #{revision || "unknown revision"}"
    )

    outcome
  end

  defp log_restart_outcome({:unconfirmed, reason} = outcome, root, done) do
    Logger.warning("[Promotion] #{done} for #{root} not confirmed: #{reason}")
    outcome
  end

  defp log_restart_outcome({:failed, reason} = outcome, root, done) do
    Logger.error(
      "[Promotion] #{done} FAILED for #{root}, application not confirmed up: #{reason}"
    )

    outcome
  end

  defp log_restart_outcome({:unexpected, other} = outcome, root, done) do
    Logger.error(
      "[Promotion] #{done} for #{root} returned something unexpected: #{inspect(other)}"
    )

    outcome
  end

  # A failed deployment is not silence: the agent was already told QA can
  # start, so a failure is sent as a correction. A confirmation is sent too —
  # an agent may be holding its task for it. `nil` means nobody to tell (a
  # Claude Code session or operator); the recipient is passed down from the
  # tool call, never guessed.
  defp tell_the_agent(outcome, _scope, _root, _done, nil), do: outcome

  # A batch the promotion queue landed tells everyone whose work was in it.
  defp tell_the_agent(outcome, scope, root, done, agent_ids) when is_list(agent_ids),
    do: Enum.reduce(agent_ids, outcome, &tell_the_agent(&2, scope, root, done, &1))

  defp tell_the_agent({:confirmed, revision} = outcome, scope, root, done, agent_id) do
    text =
      "The #{done} from your promotion is confirmed: the application at #{root} " <>
        "is up and serving #{revision || "an unreported revision"}. Your merged " <>
        "work is live — nothing more to wait for."

    deliver(scope, agent_id, text, "restart confirmation")
    outcome
  end

  # By here `verify_unconfirmed/3` has settled a lost acknowledgement, so a
  # correction is a real failure or an app verified still on the old commit.
  defp tell_the_agent({:failed, reason} = outcome, scope, root, _done, agent_id) do
    text =
      "Correction on the promotion I just reported. The merge landed, but the " <>
        "deployment that followed it failed, so the application at #{root} is NOT " <>
        "serving your work — disregard the part of that message saying QA can " <>
        "start.\n\nWhat went wrong: #{reason}\n\nNothing was rolled back; the merge " <>
        "is still on the running copy. Fix what broke the restart and promote again."

    deliver(scope, agent_id, text, "restart failure")
    outcome
  end

  defp tell_the_agent(outcome, _scope, _root, _done, _agent_id), do: outcome

  # Not retried: the agent may already be acting on the first message.
  # Agents delivers it (`Agents.Events`); Promotion sits below Agents.
  defp deliver(scope, agent_id, text, what) do
    :telemetry.execute([:code_my_spec, :promotion, :report], %{}, %{
      scope: scope,
      agent_id: agent_id,
      text: text,
      what: what
    })
  end

  # "not awaited" is what `restart_acknowledgement_lost?/1` reads; keep it.
  defp deployment_dispatched_reason(%{action: :restart}) do
    "the restart is dispatched, not awaited: promote answers as soon as the " <>
      "merge lands, and the application restart runs separately. Always, " <>
      "including for a checkout whose own process this restart would " <>
      "otherwise end before it could answer."
  end

  defp deployment_dispatched_reason(%{action: :reload}) do
    "the reload is dispatched, not awaited: promote answers as soon as the " <>
      "merge lands, and the application reloads separately, restarting if " <>
      "the reload fails."
  end

  @shown_per_source 3

  defp describe(source, problems) do
    shown =
      problems
      |> Enum.take(@shown_per_source)
      |> Enum.map_join("\n", &"  #{location(&1)}: #{first_line(&1.message)}")

    "#{source} (#{length(problems)}):\n" <> shown <> more(length(problems) - @shown_per_source)
  end

  defp location(%{file_path: path, line: line}) when is_integer(line), do: "#{path}:#{line}"
  defp location(%{file_path: path}), do: path

  defp first_line(message) do
    message |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 160)
  end

  defp more(hidden) when hidden > 0, do: "\n  …and #{hidden} more"
  defp more(_hidden), do: ""

  defp problem_key(p), do: {p.source, p.file_path, p.line, p.message}
end
