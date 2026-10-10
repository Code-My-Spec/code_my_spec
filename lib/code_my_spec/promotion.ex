defmodule CodeMySpec.Promotion do
  @moduledoc """
  Getting a working copy's finished work onto the checkout the local
  application runs from, so QA tests the code that was written.

  The failure this exists to stop, measured on Broken Oaths 2026-09-09: nine
  stories reached QA whose implementation had never left the coding agent's
  worktree. QA failed all nine, correctly, because the code it tested was not
  the code that had been written — nine defects that were not defects, and nine
  stories sent back to an agent with nothing to fix.

  Two halves, and they are independent on purpose:

    * **A read model.** `on_running_copy?/2` answers, per story, whether that
      story's files are present on the running copy at the content its work
      produced. This is what the requirement graph consumes, and it is a
      question about *state* rather than about an act — which is what lets an
      agent working directly on the running copy satisfy it by arriving, with
      no branch to merge and no promotion to run.

    * **An action.** `promote/1` gates, merges, reloads the app (or restarts
      it, when the change needs that — `deployment_plan/2`), and reports what
      is being served.

  Distinct from `CodeMySpec.Deploys`, which is the infrastructure path for
  remote environments. This is not a deploy: it is how work gets onto the local
  running dev copy.

  ## Where the merge happens

  In the *running* checkout, merging the promoting copy's branch by name. The
  two checkouts share an object store — the agent's copy is a worktree of the
  one the app runs from — so no remote is involved and nothing is pushed.

  One target, taken from the project's designation rather than from the
  promoting agent: "the running dev copy sits on main; a promotion has exactly
  one merge target." An agent that could name its target could name the wrong
  one, and "which branch is the app actually running?" becomes a question with
  two answers.

  ## Why the deployment is a recipe

  `promote/1` asks the main copy's harness to bring the app current rather
  than doing it itself, and the harness runs project recipes: `just reload`
  (migrate, let the code reloader compile, health-check) by default, `just
  serve` behind a restart. Both are app-specific — deps, migrations, assets,
  and for this project a harness on a second port — and
  `CodeMySpec.Workspaces` is not it: that runs a *preview* instance out of
  `~/.codemyspec/workspaces/<container>/<app>`, a different app in a different
  directory.

  A recipe is a seam the project owns and can read. A project with no
  `reload` recipe is restarted, as before.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Analysis,
      CodeMySpec.BddSpecs,
      CodeMySpec.BootVersion,
      CodeMySpec.Environments,
      CodeMySpec.Files,
      CodeMySpec.Problems,
      CodeMySpec.Promotion.RunningCopy,
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
  alias CodeMySpec.Promotion.Lock
  alias CodeMySpec.Promotion.Runner
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation.Blocking
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.AppTransport
  alias CodeMySpec.WorkingCopies.WorkingCopy

  # ----------------------------------------------------------------- read model

  # The verdict itself lives in `Promotion.RunningCopy`, a leaf the requirement
  # graph reads too: the graph sits below promotion and must not call it.
  defdelegate running_copy_check(scope, entity), to: CodeMySpec.Promotion.RunningCopy
  defdelegate running_copy_verdicts(scope, stories), to: CodeMySpec.Promotion.RunningCopy

  # -------------------------------------------------------------- the promotion

  @doc """
  Gate, merge, restart, and report what the application is serving.

  Refuses rather than half-finishes. Every refusal names the thing the agent
  has to act on — the problem holding the gate, the file that conflicts, the
  work it has not committed — because a refusal an agent cannot act on stops
  the pipeline just as surely as a bug.

  One at a time, per project. `Lock.with_lock/2` holds the project's lock for
  the whole of `promote_into/2` — gate through restart — because a promotion
  landing between another one's merge and its restart is the same race with
  its window moved: the surviving build is still decided by timing rather
  than by either agent, and QA still cannot tell which one it got (db97272b).
  A second caller is refused outright rather than queued, naming when the
  first promotion started — a queued promotion whose branch has since moved
  on would be a merge nobody asked for.

  `notify:` is the agent to tell how the deployment ended — confirmed or
  failed — after this has answered.

  The answer goes out as soon as the merge lands, which means it is sent before
  anybody knows whether the application came back — it says so, but it also
  says QA can start. When the restart then fails, that earlier message is wrong
  and the only party who can act on the correction is whoever received it.
  The `promote` tool is the only caller that knows who that was — the agent id
  on its frame — so it passes it down rather than the restart path guessing
  (0060d67d).

  `nil`, and a caller that omits it, mean nobody is waiting to be told — a
  Claude Code session or an operator has no conversation, and the log is the
  record.

  `story_number` names the story being promoted, not a target (main is the
  only one). That story alone is latched (`specs_ready`) and stamped
  (`promoted_version`), and only if all of its spex pass on the promoting
  copy's certifying run — otherwise the promote is refused naming them
  (e1174640). `nil` is work that is not a story's — a fix from an issue — and
  merges and restarts without latching or stamping anything.

  `restart: true` restarts the app instead of reloading it; see
  `deployment_plan/2` for when a promote restarts on its own.

  `verify_within:`/`verify_every:` (ms) bound how long a restart whose
  acknowledgement was lost is checked against what the app is serving
  (08744186).
  """
  @spec promote(Scope.t(), integer() | String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, map()}
  def promote(%Scope{} = scope, story_number, opts \\ []) do
    result =
      with :ok <-
             CodeMySpec.Promotion.HandoffGate.check(
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

  The procedure the ready-for-QA gate and promotion share (John, 2026-10-02):
  ready-for-QA stamps the commit this answers for, promotion merges it. A
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

    with {:ok, pre} <- Runner.precheck(scope, from.root, from.id, main),
         {:ok, head} <- reported_head(pre, named),
         {:ok, swept} <- gate(scope, head, opts),
         :ok <- story_spex_pass(scope, story, named) do
      {:ok, %{head: head, certified_by: swept, precheck: pre}}
    end
  end

  defp story_to_promote(_scope, nil), do: {:ok, nil}

  defp story_to_promote(scope, number) do
    case Stories.get_story_by_number(scope, number) do
      nil -> {:error, %{reason: "there is no story #{inspect(number)} in this project."}}
      story -> {:ok, story}
    end
  end

  # Kept from `report_to/3`, which is gone: the log answers "what did it decide"
  # independently of who received it. That mattered enormously while delivery was
  # a message to an agent and could fail silently. It still earns its place, now
  # as a record beside an answer the caller already has rather than instead of
  # one.
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

  # Working on the running copy. There is no branch to merge — the work is
  # already where a promotion would put it — so a promotion here is the other
  # half on its own: start what serves it.
  #
  # This used to refuse, and the refusal became unreachable-by-design the moment
  # the gate started requiring the application to answer: an agent on the
  # running copy with a dead app was told to promote, and promote told it there
  # was nothing to merge. Neither statement was wrong and there was no way out
  # of the pair.
  #
  # No gate, because nothing crosses. The story is held to the merge path's own
  # rule, minus the merge (e1174640): its spex must pass on main's certifying
  # spex run — one at main's HEAD (28d72f8a), started here if there is none —
  # and it is then latched at that HEAD and stamped with the version main
  # already carries. Red or missing spex refuse, as a merge would.
  defp promote_into(
         %Scope{active_working_copy_id: id} = scope,
         %WorkingCopy{id: id} = running,
         story,
         opts
       ) do
    named = named_copy(id)

    with {:ok, %{head: head, version: version}} <- current_of(scope, running, named),
         :ok <- runs_at(scope, ["spex"], head, named, opts),
         :ok <- story_spex_pass(scope, story, named) do
      stamp_promoted_story(scope, story, version, head, id)
      notify_team_free(scope, id, story)

      # Always a restart: nothing was merged, so there is no diff to judge a
      # reload by, and this path exists for an app that is down.
      plan = %{
        action: :restart,
        reason: "nothing was merged, so there is no change to judge a reload by"
      }

      # `deploy/4` always answers `{:error, %{reason: ...}}` — dispatched, not
      # awaited (54aa534c) — so this wraps it as the success it is.
      {:error, reason} = deploy(scope, running, plan, Keyword.put(opts, :expect, %{to: head}))

      {:ok, %{restarted: running.root, serving: %{unconfirmed: reason}, deployment: plan}}
      |> with_story(story, version)
    else
      {:pending, pending} -> {:ok, %{pending: pending}}
      {:error, _} = error -> error
    end
  end

  # No post-merge check, and no wait for the merge to be *served* — both by
  # design (54aa534c, phase two, John: "we should guarantee with our
  # preconditions that the merge will be clean... deployment should follow
  # async").
  #
  # There is nothing left for a post-merge check to find. `gate/3` already
  # certified the promoting commit clean, and `Runner.merge/4` is
  # now `--ff-only` — which only ever succeeds by making the running copy's
  # tree byte-identical to the branch tip that was just certified, never by
  # combining it with anything else. A tree that cannot differ from what was
  # already gated has nothing new to carry into it.
  #
  # So this returns as soon as the merge lands, and `restart/3` dispatches
  # the actual deployment — the application restart, with migrations if the
  # recipe runs them — detached rather than awaited. `Lock.with_lock/2` is
  # now held for a database read and a git fast-forward: neither one can run
  # long, and neither one is what used to make a contended promotion cost
  # sixteen minutes.
  #
  # In order (28d72f8a): the copy contains main, its tree is clean, every
  # analyzer has a clean run at its HEAD (started now, and answered as
  # pending, where one is missing), and then exactly that commit is merged.
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

      land_into(scope, running, from, candidate, [{story, from.id}], opts)
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
  every story in the batch. `stories` pairs each story (or nil, for work that
  is not a story's) with the working copy it came from.
  """
  @spec land(
          Scope.t(),
          WorkingCopy.t(),
          String.t(),
          [{Stories.Story.t() | nil, Ecto.UUID.t()}],
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

    with {:ok, merge_result} <- Runner.merge(scope, running.root, head, from.id),
         # Before stamping or restarting: a refusal here has rolled the merge back.
         {:ok, _} <-
           Runner.sync_submodule(scope, running.root, from.root, merge_result, from.id) do
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

      # Not `version`. A no-op merge originates nothing and still has a story to
      # stamp — see `Steps.current_version/2` for why those are different
      # questions and what it cost to find out.
      :ok = record_landed_stories(scope, stories, stamp_version, Map.get(merge_result, :after))

      # `head` and `after` are the same commit now that a promotion tags rather
      # than commits a version bump; both are read so a result from either
      # shape works.
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

  # `9afcbbdf`: this used to name `running.root` unconditionally — the merge
  # target, never the copy a `gate/3` refusal is actually about. `gate/3`'s own
  # reasons now carry `:working_copy`; fall back to the merge target only for
  # refusals that happen before the gate runs (no working copy on the scope, an
  # unreported checkout).
  defp refused(running, reason) do
    named = Map.get(reason, :working_copy, running.root)

    Logger.warning(
      "[Promotion] refused for #{named}: #{Map.get(reason, :reason, inspect(reason))}"
    )
  end

  # `restart/3` always answers `{:error, %{reason: ...}}` now — dispatched,
  # never awaited, for every promotion (54aa534c, phase two) — so there is
  # only the one clause. Kept as its own function, rather than inlined at the
  # call site, because `restart_acknowledgement_lost?/1` is the part that
  # still has to be checked: a lost acknowledgement is reported as what it
  # is — merged, restart unconfirmed — never as a flat failure. The merge
  # has already happened by the time this runs, so reporting failure here is
  # not merely confusing, it is false about the part that matters: an agent
  # told its promotion failed promotes again, and each retry restarts the
  # shared dev server every other working copy on the box is using.
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
  defp with_stories(result, [{story, _copy_id}], version), do: with_story(result, story, version)

  defp with_stories({:ok, report}, stories, version) do
    numbers = for {%{number: number}, _copy_id} <- stories, do: number
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

  # The promoted story alone, latched and stamped in one write with the
  # promote's commit (e1174640). No other story is touched: a project-wide
  # sweep stamped stories whose code sat unmerged on a different copy. `nil`
  # (no tag and no `mix.exs` version to count from) latches without stamping.
  #
  # A write failure is logged and swallowed rather than turned into a
  # promotion failure: the merge is real and already on disk by the time this
  # runs, and reporting it as a failed promotion would send an agent to
  # promote again, restarting the shared dev server every other working copy
  # on the box is using, over a write that touched no code at all.
  # The story-side half of criterion 1892's team-free parity with
  # `IssueAssignment.free/2`: a story finishing by promotion sends main the
  # same offer kind an issue finishing through QA already does.
  @doc """
  What a landing does for the stories in it: each is stamped promoted at
  `version` and `commit`, and its team's freedom is announced. Also for a
  candidate main already contains (`PromotionQueue`), which has nothing to
  merge and lands as it is.
  """
  @spec record_landed_stories(
          Scope.t(),
          [{Stories.Story.t() | nil, Ecto.UUID.t()}],
          String.t() | nil,
          String.t() | nil
        ) :: :ok
  def record_landed_stories(scope, stories, version, commit) do
    for {story, copy_id} <- stories do
      stamp_promoted_story(scope, story, version, commit, copy_id)
      notify_team_free(scope, copy_id, story)
    end

    :ok
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
        Logger.warning(
          "[Promotion] merged story #{story.number} at version #{version || "none"}, but " <>
            "could not latch and stamp it: #{inspect(reason)}"
        )

        :ok
    end
  end

  # All of the promoted story's spex pass on the promoting copy's certifying
  # run. `gate/3` has already required that run at HEAD; this reads its
  # problems against the story's own spec files (`files.story_id`, not a
  # directory name — see `FixBddSpecs.story_spex_problems/2` for what parsing
  # names cost). A story with no linked spec files has nothing that passed, so
  # it refuses rather than latching on an empty list.
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

  # Every red spex on the story refuses it (John, 2026-10-05): the story's spex
  # files on the copy, by its own rows and by the criteria they name.
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
    case Runner.current(scope, root, id) do
      {:ok, %{head: head} = current} when is_binary(head) ->
        {:ok, %{head: head, version: Map.get(current, :version)}}

      other ->
        {:error,
         %{reason: "could not read #{root}'s HEAD: #{inspect(other)}", working_copy: named}}
    end
  end

  # Main's HEAD, which the promoting copy must contain. Asked through the
  # promoting copy's harness, the one the merge runs through.
  defp main_head(scope, running, from) do
    case Runner.current(scope, running.root, from.id) do
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
    case Runner.current(scope, from.root, from.id) do
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

  # `{:shutdown, :draining}` and `:not_connected` are documented elsewhere as
  # "the server went away — someone restarted :4000". For every other operation
  # that reading is right. For this one the restart *is* the operation
  # succeeding, which is why the shape has to be read against the op that
  # produced it rather than on its own.
  @doc """
  Whether a restart failure is the expected shape of a restart that worked.

  Public because it is the rule, not an implementation detail: "this error means
  the opposite of what it says" is exactly the kind of claim that should be
  written down once and checked, rather than reimplemented by each caller who
  gets bitten.

  `{:shutdown, :draining}` and `:not_connected` are documented elsewhere as "the
  server went away — someone restarted :4000", and for every other operation
  that reading is right. For this one the restart *is* the operation succeeding,
  so the shape has to be read against the op that produced it rather than on its
  own.
  """
  @spec restart_acknowledgement_lost?(term()) :: boolean()
  def restart_acknowledgement_lost?(%{reason: reason}) when is_binary(reason) do
    String.contains?(reason, "promotion_restart") or
      String.contains?(reason, "not_connected") or
      String.contains?(reason, "draining") or
      String.contains?(reason, "not awaited")
  end

  def restart_acknowledgement_lost?(_), do: false

  # Nothing here is long-running, which is why there is no async variant any more.
  #
  # `promote_async/2` wrapped the whole thing in a task because "a promotion
  # sweeps analyzers before it will call a copy clean, and a sweep is minutes".
  # That stopped being true at 54aa534c: the gate no longer awaits a sweep, it
  # reads the runs already on file. What was left is three DB reads, a `git
  # status`, a `--ff-only` merge, and a restart that is dispatched rather than
  # awaited. Measured: a full `promote/2` including the merge completes in 0.3s
  # in `AsyncDeploymentTest`.
  #
  # The wrapper outlived its reason and cost more than it saved. Every refusal
  # was computed in milliseconds and then reported through a channel that only
  # exists for Alloy agents, so a Claude Code session, a script or curl got
  # "Promotion started." for a promotion that had already been refused — a false
  # success, indistinguishable from a slow one. John: "Promotion should return
  # immediately on failure with a clear reason why... I bet this has been
  # fucking us for a while." It had: one was silently refused for a stale sweep
  # and nobody knew for half an hour.
  #
  # So `promote/2` is the whole API. The restart stays detached inside it and
  # `outcome_text/1` says so in the answer, which is the one thing that genuinely
  # must not be waited on.

  defp outcome_label({:ok, %{pending: _}}), do: "pending"
  defp outcome_label({:ok, _}), do: "promoted"
  defp outcome_label({:error, _}), do: "refused"
  defp outcome_label(_other), do: "returned something unexpected"

  # The standard outcome now, not an edge case (54aa534c, phase two): the
  # restart is always dispatched, never awaited, so this is what a normal,
  # successful promotion reports every time — not a fallback for when
  # something unusual happened to the acknowledgement. Worded as the expected
  # completion, not as an anomaly needing explanation, for the same reason
  # `Steps.not_fast_forward/3`'s wording says divergence is routine: this is
  # about to become the most-read string in the system.
  @doc """
  What a promotion's result says, in the words the caller reads.

  Public because the caller now receives this. It used to be written only into
  `web.log` and a message to an agent, which is why a refusal reached nobody
  without one.
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

  # A read of the ledger, keyed on the commit (28d72f8a), not on fingerprints.
  #
  # Fingerprint freshness is what stalled the fleet: two definitions of fresh
  # (849f8e7a), a tree that moved mid-run (53465/53636), a run started 22s
  # before the commit it was meant to certify (27c4070c). A run now answers for
  # a commit only if the harness saw it start on a clean tree at that commit
  # and finish there (`Run.at_commit?/2`).
  #
  # A missing run is started, not waited on: the gate answers "pending" at
  # once and the result reaches the promoting agent through `requested_by`
  # when it lands. `Lock.with_lock/2` is still held for reads and a merge only.
  #
  # Logged before anything else here runs, so a gate that reads the wrong
  # copy's problems (`02796b61`) is diagnosable from this log line alone.
  @doc """
  Whether the promoting copy (`scope.active_working_copy_id`) may merge `head`.

  Every analyzer needs a run at `head` (`Analysis.answer_at_commit/3`). The
  problems those runs recorded must be zero (John, 2026-10-05: every red spex
  refuses, latched or not). Compiler, credo and exunit findings refuse at
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
      # Every source, whatever the project's config (c6f54b90): config decides
      # what the stop hook sweeps, never what promote demands. Narrowing this
      # would let a project promote a commit `exunit` had never once run against.
      {answered, missing} = answers_at(scope, Run.sources(), head)

      case blocking_problems(scope, Map.keys(answered)) do
        [] -> certify(scope, answered, missing, head, named, opts)
        problems -> gate_result(problems, named)
      end
      |> log_gate(working_copy_id, head)
    end
  end

  # The copy the gate judges, resolved here rather than left to the read.
  #
  # `blocking_problems/2` reads problems through
  # `ProblemRepository.scope_to_harness/2`, which treats a scope with no
  # `active_working_copy_id` as "the default copy" (`WorkingCopies.default_id/1`)
  # because a plain project-wide read has no copy to narrow to. That is right for
  # a page showing a project-wide count, and wrong here: the gate is judging one
  # checkout's commit, and with none named there is nothing to judge. Left
  # unresolved it quietly judged the default copy's problems instead, so a caller
  # with no working copy was refused over findings on a checkout it had never
  # named and could not fix (`02796b61`).
  #
  # Refused, not narrowed to a copy nobody asked for. `gate/3`'s callers resolve a
  # copy before they get here (`promoting_copy/2`), so this is the case where
  # nobody did.
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

  # One run per missing source, unless one is already running at `head` — a
  # second would queue behind it and certify the same commit twice.
  #
  # A run already running there, or one a start joined, was requested by
  # somebody else, so the agent in `opts[:notify]` is added as a waiter on it:
  # told when it lands, and not nudged meanwhile (`awaiting_runs?/3`).
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

  # `9afcbbdf` ask 1: every refusal names the copy the findings belong to, which
  # `02796b61` showed can silently be a *different* checkout than the one that
  # called, so a caller can tell in one read which copy the gate resolved to.
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

  # Only the sources whose latest run is at the certified commit: a problem
  # recorded by a run at another commit describes a different tree.
  #
  # Credo and compiler findings block whatever the stop hook's mode says: a
  # warning let through here lands on main and blocks every other copy's
  # promote until someone cleans it up (v2.0.162's two AliasUsage findings).
  # Exunit and spex go through `Blocking.enforceable/2`, which drops only spex
  # findings with no location — the same rule the stop hook uses.
  #
  # Whether an advisory finding can block at all is `Validation.blockable/2`'s
  # answer, shared with task evaluation and the analysis digest.
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

  Reload by default (John, 2026-10-02): a restart of :4000 kills every
  in-flight agent turn and analysis run on the box, and the app's own code
  reloader takes most changes. Restart when `changed` (the merge's paths)
  touches anything in `BootVersion.restart_paths/0`, when it is `nil` (not
  readable, so not judged), when the harness cannot reload (`reload_supported:
  false`), or when the caller asks (`restart: true`). A reload that then fails
  restarts too, inside the same deployment.

  This replaces "always, never conditionally". The worry behind that rule — a
  second implementation of the reload rules, wrong and silent — is answered by
  keeping the list short and in one place, and by the health check: a reload
  that did not take reports unhealthy and falls back to a restart.
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

  # Dispatched, never awaited (54aa534c, phase two — John: "the deployment
  # should follow async"). `promote/1` answers as soon as the merge lands;
  # the actual deployment — migrations, if the recipe runs them, and the
  # application coming back up — runs in a detached task this call does not
  # wait on.
  #
  # Not optional for a self-hosted checkout: a restart kills whatever is
  # listening on :4000, and when that is this very BEAM — the one running the
  # promotion — running it inline takes the promotion's own Task down with
  # it, before it can answer. No exception to catch, no `after` block
  # guaranteed to run: `Promotion.Lock`'s own moduledoc already records that
  # a server restart comes back with an empty lock table, because nothing
  # survives to release it. Dispatching detached is what lets this process
  # answer at all in that case. Doing it unconditionally — for a remote
  # harness too — means one mechanism rather than a path that waits and a
  # path that cannot. A reload leaves this BEAM up, but its code reloader
  # swaps modules under this task, and a failed reload restarts anyway, so a
  # reload is dispatched the same way.
  #
  # Reuses the shape `e721ccf0d` already built for a remote harness's dropped
  # channel: `merged/5` reads this as "merged, restart unconfirmed" either
  # way, because that is the same claim to a caller regardless of which
  # mechanism produced it — do not promote again to find out.
  #
  # `preview_status` is claimed "serving" right here, unconditionally, rather
  # than after a confirmation that no longer arrives. The gate reads
  # `preview_status`, and the only other writer is the harness on its next
  # sync — without this claim, an agent refused because its application was
  # down promoted, and the very next gate read the same stale `down` a sync
  # had not yet overwritten, asking it to promote again forever. A claim
  # rather than an observation, deliberately: over-claiming costs one QA
  # attempt that meets a real failure and reports it; under-claiming costs an
  # agent that cannot get out of the gate at all.
  defp deploy(%Scope{} = scope, %WorkingCopy{root: root} = running, plan, opts) do
    dispatch_deployment(scope, root, running.id, plan, opts)
    {:ok, _} = WorkingCopies.record_preview_status(running, "serving")
    {:error, %{reason: deployment_dispatched_reason(plan)}}
  end

  # Detached rather than linked or awaited: this process may not exist by the
  # time a restart returns, and it must not need to for the restart to
  # have happened. `CodeMySpec.TaskSupervisor` is the same one `promote_async/2`
  # already reports through for the same reason — fire, do not wait.
  #
  # `Runner.restart/4`'s own result is logged here rather than discarded,
  # because dispatched-and-forgotten used to mean exactly that: a `just
  # restart` failing on the far side of this task — a broken migration, a
  # compile error the merge itself couldn't have caught since nothing crosses
  # here that wasn't already gated — had nowhere to go. The caller had already
  # been told "merged, restart unconfirmed" and moved on; this is the one
  # place that outcome is ever actually resolved one way or the other.
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

  # One reading of the outcome, made once and consulted twice, rather than two
  # readings that can disagree.
  #
  # They did disagree, and the shape of it is the reason this function exists
  # rather than a comment: `tell_the_agent/4` consulted
  # `restart_acknowledgement_lost?/1` and correctly said nothing, while
  # `log_restart_outcome/2` consulted nothing and wrote `restart FAILED` at
  # error level for that same restart. Both halves were right on their own
  # terms, so neither looked wrong, and the only witness was a log line
  # contradicting a decision made three lines below it.
  #
  # Only the log has a reader who was not present for the decision, which is
  # what made the disagreement expensive: six error-level lines claiming the
  # application was not up, while :4000 answered 200 and served the new
  # revision, and a quarter of an hour spent believing them.
  #
  # A third consumer is now free. It reads the verdict; it cannot re-derive a
  # different one.
  defp classify_restart({:ok, %{revision: revision}}), do: {:confirmed, revision}

  defp classify_restart({:error, %{reason: reason} = error}) do
    if restart_acknowledgement_lost?(error),
      do: {:unconfirmed, reason},
      else: {:failed, reason}
  end

  defp classify_restart(other), do: {:unexpected, other}

  # 08744186: a lost acknowledgement used to end here, "dispatched, not yet
  # confirmed", whether the restart happened or the channel died with it. Ask
  # the app what it is serving, through the same `AppTransport` status path
  # every copy's app answers, until it reports the merged commit or the bound
  # runs out — then say which: serving <commit>, or still on <old>.
  #
  # Only an app that answered on the wrong commit is a failure. One that never
  # answered stays unconfirmed: nothing was learned, and calling it failed
  # tells an agent to fix a restart that may have worked.
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

  # Story 1046, criterion 3437 — "a failed deployment is not silence" (0060d67d).
  #
  # The log line above is not enough on its own, and it is worth being exact
  # about why rather than calling it insufficient. The promotion already
  # answered, seconds ago, with "Promoted ... QA on these stories can start
  # against the merge". If the restart then fails, that message is wrong and
  # nothing retracts it: the agent proceeds on the last thing it was told, and
  # the only record is a line in web.log that nobody who was not already
  # tailing it will read. From the agent's side that is silence.
  #
  # A confirmed restart is told too. It used to be skipped as noise, and an
  # agent that decided to hold its task until the restart was confirmed then
  # waited on a confirmation that only ever reached web.log (metric_flow,
  # 2026-09-27).
  #
  # `nil` is the ordinary case rather than an oversight: a Claude Code session
  # or an operator has no conversation to be told in, and the log is the record
  # there. Only the tool call knows which agent received the first answer,
  # which is why this is passed down rather than looked up — guessing the
  # recipient would mean messaging an agent that never saw the first one.
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

  # A lost acknowledgement is not a failure by itself — see
  # `restart_acknowledgement_lost?/1`. `verify_unconfirmed/3` settles it
  # against what the app is serving before this runs, so a correction here is
  # either a real failure or an app verified still on the old commit — never a
  # retry over a restart that already worked, which would restart the shared
  # dev server every other working copy on the box is using.
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

  # Logged rather than retried, matching `report_to/3`: the agent may already be
  # acting on the first message, and a delivery loop does not fix that.
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
