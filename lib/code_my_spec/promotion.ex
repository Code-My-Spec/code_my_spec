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

    * **An action.** `promote/1` gates, merges, restarts, and reports what is
      being served.

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

  ## Why the restart is a recipe

  `promote/1` shells out to `just restart` in the running checkout rather than
  bringing the app up itself. Restarting a Phoenix app is app-specific — deps,
  migrations, assets, and for this project a harness on a second port — and
  `CodeMySpec.Workspaces` is not it: that runs a *preview* instance out of
  `~/.codemyspec/workspaces/<container>/<app>`, a different app in a different
  directory.

  A recipe is a seam the project owns and can read. `just restart` is also
  where the unconditional part lives: `Workspaces.boot/1` deliberately returns
  a running workspace as-is rather than starting it twice, which is the exact
  opposite of what a promotion needs.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Analysis,
      CodeMySpec.Environments,
      CodeMySpec.Files,
      CodeMySpec.Problems,
      CodeMySpec.Promotion.RunningCopy,
      CodeMySpec.Stories,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils,
      CodeMySpec.Validation,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Files
  alias CodeMySpec.Problems.ProblemRepository
  alias CodeMySpec.Promotion.Lock
  alias CodeMySpec.Promotion.Runner
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation
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

  `story_number` is required: it names the story being promoted, not a target
  (main is the only one). That story alone is latched (`specs_ready`) and
  stamped (`promoted_version`), and only if all of its spex pass on the
  promoting copy's certifying run — otherwise the promote is refused naming
  them (e1174640).

  `verify_within:`/`verify_every:` (ms) bound how long a restart whose
  acknowledgement was lost is checked against what the app is serving
  (08744186).
  """
  @spec promote(Scope.t(), integer() | String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, map()}
  def promote(%Scope{} = scope, story_number, opts \\ []) do
    result =
      with {:ok, story} <- story_to_promote(scope, story_number),
           {:ok, running} <- running_copy(scope) do
        Lock.with_lock(running.project_id, fn -> promote_into(scope, running, story, opts) end)
        |> unlocked()
      end

    log_outcome(result)
  end

  defp story_to_promote(_scope, nil) do
    {:error,
     %{
       reason:
         "promote needs the number of the story you are promoting. That story is " <>
           "latched and stamped promoted when its spex pass on this copy; main is " <>
           "still the only place the work goes."
     }}
  end

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
  # spex run, and it is then latched at main's HEAD and stamped with the
  # version main already carries. Red or missing spex refuse, as a merge would.
  defp promote_into(
         %Scope{active_working_copy_id: id} = scope,
         %WorkingCopy{id: id} = running,
         story,
         opts
       ) do
    named = named_copy(id)

    with :ok <- spex_certified(scope, named),
         :ok <- story_spex_pass(scope, story, named) do
      %{head: head, version: version} = current_of(scope, running)
      stamp_promoted_story(scope, story, version, head)

      # `restart/3` always answers `{:error, %{reason: ...}}` — dispatched, not
      # awaited (54aa534c) — so this wraps it as the success it is.
      {:error, reason} = restart(scope, running, Keyword.put(opts, :expect, %{to: head}))

      {:ok, %{restarted: running.root, serving: %{unconfirmed: reason}}}
      |> with_story(story, version)
    end
  end

  # No post-merge check, and no wait for the merge to be *served* — both by
  # design (54aa534c, phase two, John: "we should guarantee with our
  # preconditions that the merge will be clean... deployment should follow
  # async").
  #
  # There is nothing left for a post-merge check to find. `gate/1` already
  # certified the promoting branch clean and fresh, and `Runner.merge/4` is
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
  defp promote_into(%Scope{} = scope, running, story, opts) do
    with {:ok, from} <- promoting_copy(scope, running),
         {:ok, %{branch: branch} = pre} <- Runner.precheck(scope, from.root, from.id),
         {:ok, swept} <- gate(scope),
         :ok <- story_spex_pass(scope, story, named_copy(from.id)),
         {:ok, merge_result} <- Runner.merge(scope, running.root, branch, from.id),
         # Before stamping or restarting: a refusal here has rolled the merge back.
         {:ok, _} <-
           Runner.sync_submodule(scope, running.root, from.root, merge_result, from.id) do
      version = Map.get(merge_result, :version)
      stamp_version = Map.get(merge_result, :stamp_version)

      Logger.info(
        "[Promotion] merged #{branch} into #{running.root} " <>
          "(#{Map.get(merge_result, :before) || "?"} -> #{Map.get(merge_result, :after) || "?"}), " <>
          "version #{version || "none"}, stamping #{stamp_version || "none"}, " <>
          "certified by #{describe_certifications(swept)}, dispatching restart"
      )

      # Not `version`. A no-op merge originates nothing and still has a story to
      # stamp — see `Steps.current_version/2` for why those are different
      # questions and what it cost to find out.
      stamp_promoted_story(scope, story, stamp_version, Map.get(merge_result, :after))

      expect = %{from: Map.get(merge_result, :before), to: Map.get(merge_result, :after)}

      scope
      |> restart(running, Keyword.put(opts, :expect, expect))
      |> merged(branch, running, swept, Map.get(pre, :untracked, []), version)
      |> with_story(story, stamp_version)
    else
      {:error, reason} = error ->
        # `9afcbbdf`: this used to name `running.root` unconditionally — the
        # merge target, never the copy a `gate/1` refusal is actually about.
        # `gate/1`'s own reasons now carry `:working_copy`; fall back to the
        # merge target only for refusals that happen before the gate runs
        # (no working copy on the scope, an unreported checkout).
        named = Map.get(reason, :working_copy, running.root)

        Logger.warning(
          "[Promotion] refused for #{named}: #{Map.get(reason, :reason, inspect(reason))}"
        )

        error
    end
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

  defp with_story({:ok, report}, story, version),
    do: {:ok, Map.put(report, :story, %{number: story.number, version: version})}

  defp with_story(error, _story, _version), do: error

  # The promoted story alone, latched and stamped in one write with the
  # promote's commit (e1174640). No other story is touched: a project-wide
  # sweep stamped stories whose code sat unmerged on a different copy. `nil`
  # (no `mix.exs` to read a version from) latches without stamping.
  #
  # A write failure is logged and swallowed rather than turned into a
  # promotion failure: the merge is real and already on disk by the time this
  # runs, and reporting it as a failed promotion would send an agent to
  # promote again, restarting the shared dev server every other working copy
  # on the box is using, over a write that touched no code at all.
  defp stamp_promoted_story(scope, story, version, commit) do
    opts = [at: DateTime.utc_now(), commit: commit]

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
  # run. `gate/1` has already required that run to be fresh; this reads its
  # problems against the story's own spec files (`files.story_id`, not a
  # directory name — see `FixBddSpecs.story_spex_problems/2` for what parsing
  # names cost). A story with no linked spec files has nothing that passed, so
  # it refuses rather than latching on an empty list.
  defp story_spex_pass(scope, story, named) do
    paths =
      scope
      |> Files.list_story_files(story.id)
      |> Enum.filter(&(&1.role == :bdd_spec))
      |> MapSet.new(& &1.path)

    failing =
      scope
      |> ProblemRepository.list_project_problems(source: "spex")
      |> Enum.filter(&MapSet.member?(paths, &1.file_path))

    spex_verdict(story, paths, failing, named)
  end

  # The running-copy path has no `gate/1` to have required a fresh run, so it
  # asks for the one it reads.
  defp spex_certified(scope, named) do
    if "spex" in stale_sources(scope),
      do: {:error, not_certified(["spex"], named)},
      else: :ok
  end

  # A failure to read main's HEAD or version latches without them rather than
  # refusing: the spex already passed, and nothing here moved.
  defp current_of(scope, %WorkingCopy{root: root, id: id}) do
    case Runner.current(scope, root, id) do
      {:ok, current} ->
        %{head: Map.get(current, :head), version: Map.get(current, :version)}

      {:error, reason} ->
        Logger.warning(
          "[Promotion] could not read #{root}'s HEAD and version: #{inspect(reason)}"
        )

        %{head: nil, version: nil}
    end
  end

  defp spex_verdict(story, paths, [], named) do
    if MapSet.size(paths) == 0 do
      {:error,
       %{
         reason:
           "story #{story.number} has no spex linked on #{named}, so nothing says " <>
             "its spex pass. Write them (or sync so they link), then promote again.",
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
           describe(failing) <>
           "\n\nFix them, let spex run, then promote again.",
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
  # That stopped being true at 54aa534c: `gate/1` no longer runs a sweep, it
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
  def outcome_text({:ok, %{merged: branch, serving: %{unconfirmed: _}}}) do
    "Your promotion merged #{branch} onto the running dev copy. The application " <>
      "restart is running now in the background, not waited on — that is by " <>
      "design, so a promotion answers in seconds regardless of how long the " <>
      "restart takes or whether it is this checkout's own process restarting. " <>
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
  def outcome_text({:ok, %{restarted: root, serving: %{unconfirmed: _}}}) do
    "Your promotion finished. There was nothing to merge — you are working on " <>
      "the running copy — so the application at #{root} is restarting now in " <>
      "the background, not waited on. Do not promote again just to check; ask " <>
      "what is serving instead."
  end

  def outcome_text({:error, %{reason: reason}}),
    do: "Your promotion did not go through. #{reason}"

  def outcome_text(other),
    do: "Your promotion returned something unexpected: #{inspect(other)}"

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

  # A read of the ledger, not a job the gate starts and waits for (54aa534c).
  #
  # It used to be the second thing: `ensure_stale_runs/3` enqueued whatever was
  # stale, then `Analysis.await_all/2` polled until this copy had no run in
  # flight. On a copy an agent is still working in, that predicate is
  # re-falsified by every edit — a run enqueued at commit A answers a tree
  # that has moved to commit B by the time it completes, `await_all/2` sees a
  # run in flight again, and the wait never ends. Measured live 2026-09-12:
  # 97.6% of every analysis run this project has ever recorded was superseded
  # before it finished, and one promotion held the project's lock for sixteen
  # minutes because its own session kept editing the very file the promotion
  # was about, re-staling the sweep the gate was waiting on each time.
  #
  # The question the gate actually needs answered — is this commit clean —
  # has usually already been answered by the time an agent promotes; a stop
  # hook runs analysis on every turn. So this reads whether the CURRENT
  # commit already has a completed run for every source
  # (`Analysis.fresh_sources/2` — the same input/completed-fingerprint
  # comparison the stop hook's own staleness reporting already uses) and
  # refuses immediately, by name, if it does not. Nothing is enqueued, nothing
  # is awaited, and `Lock.with_lock/2` is now held for a ledger read, a merge
  # and a restart — seconds — rather than a wait with no guaranteed end.
  # Logged before anything else here runs, so a gate that reads the wrong
  # copy's problems — `02796b61`: `active_working_copy_id` resolved to a
  # different harness's id, and the promoting copy got charged for another
  # checkout's finding — is diagnosable from this log line alone instead of
  # costing a psql join of `problems` to `working_copies` after the fact. A
  # nil id never reaches here at all (`promoting_copy/2` refuses first); this
  # is for the harder case, where a present id turns out to be the wrong one.
  defp gate(
         %Scope{active_working_copy_id: working_copy_id, active_project_id: project_id} = scope
       ) do
    Logger.info(
      "[Promotion] gate for project #{project_id}: active_working_copy_id=#{working_copy_id}"
    )

    scope
    |> blocking_problems(nil)
    |> gate_known(scope, named_copy(working_copy_id))
  end

  # `9afcbbdf` ask 1: every refusal named the merge target's root
  # (`promote_into/3` logs `running.root` unconditionally), never the copy the
  # findings actually belong to — which the caller has no way to learn short of
  # a psql join, and which `02796b61` showed can silently be a *different*
  # checkout than the one that called. Carried into both error reasons below
  # so a refusal is self-contained: a caller comparing this against its own
  # root can tell in one read whether the gate resolved to a copy other than
  # its own, rather than needing the server log line this module already
  # wrote for the same reason.
  defp named_copy(nil), do: "no working copy on this scope"

  defp named_copy(working_copy_id) do
    case WorkingCopies.fetch(working_copy_id) do
      {:ok, %WorkingCopy{root: root}} when is_binary(root) -> "#{working_copy_id} (#{root})"
      _ -> working_copy_id
    end
  end

  # A problem already recorded answers immediately, staleness or not — a real
  # finding does not stop being real because the run that found it is not the
  # newest one. Only an *empty* list needs the staleness check, because an
  # empty list from a stale run is not evidence of anything: "no problems
  # recorded" and "no problems" are different claims, and closing that gap
  # used to mean waiting for a fresh run — it now means reading whether one
  # already exists.
  defp gate_known([], scope, named), do: gate_freshness(scope, stale_sources(scope), named)
  defp gate_known(problems, _scope, named), do: gate_result(problems, named)

  defp gate_freshness(scope, [], _named), do: {:ok, certified_by(scope)}
  defp gate_freshness(_scope, stale, named), do: {:error, not_certified(stale, named)}

  # What this promote actually leaned on to call the copy clean. `gate/1`
  # never runs a check of its own — see the moduledoc above it — it reads
  # whichever runs are already on file, so two promotes seconds apart with
  # nothing re-run in between read the exact same rows and both say "clean"
  # with nothing in the response to tell them apart. Carried on `swept` so
  # reuse is visible instead of silent: two promotes citing the same
  # `finished_at` for every source verified nothing new between them, and a
  # caller that cares (or is debugging why a second promote answered
  # instantly) can tell.
  defp certified_by(scope) do
    for source <- Run.sources() do
      case Analysis.latest_answer(scope, source) do
        %Run{finished_at: finished_at} -> %{source: source, finished_at: finished_at}
        nil -> %{source: source, finished_at: nil}
      end
    end
  end

  # The log line's rendering of `certified_by/1` — a timestamp per source, so
  # the same finished_at showing up across two consecutive promotions' logs
  # is the evidence that the second one reused the first's verdict rather
  # than seeing anything new.
  defp describe_certifications(certifications) do
    certifications
    |> Enum.map_join(", ", fn
      %{source: source, finished_at: nil} ->
        "#{source} (no run on file)"

      %{source: source, finished_at: finished_at} ->
        "#{source} @ #{DateTime.to_iso8601(finished_at)}"
    end)
  end

  # `c6f54b90`: a project with `require_unit_tests: false` still refused on a
  # stale `exunit`, and it looked like a bug — the requirement graph had
  # already stopped asking for `tests_passing` under the same setting
  # (`RequirementGraph.maybe_filter_tests/2`), so the graph and the gate
  # disagreed about the same config. Tried narrowing this to match; reverted.
  # Every project-level config in this system — `require_unit_tests`, and
  # `spex`/`exunit`/`credo`'s own off|block_changed|block_all — decides what
  # the *automatic stop-hook sweep* asks for, never what *promote* demands
  # before it will ship. The graph is allowed to stop asking an agent to
  # write tests for a story; the gate is not thereby excused from checking
  # the ones that already exist still pass. Narrowing this would let a
  # project promote a commit `exunit` had never once run against.
  defp stale_sources(%Scope{} = scope) do
    fresh = Analysis.fresh_sources(scope, Run.sources())
    Enum.reject(Run.sources(), &(&1 in fresh))
  end

  # Named and specific on purpose (376e3356 already argued this once, for the
  # wait this replaces): the ambiguity between "working" and "stuck" is what
  # cost sixteen minutes to diagnose last time, and a refusal that does not
  # say which source or what to do about it recreates the same ambiguity one
  # level up.
  #
  # This reads as a new restriction before it reads as the fix it is —
  # editing after your last clean run now refuses immediately where it used
  # to just wait, sometimes forever. Said outright, because the alternative is
  # an agent discovering the difference by hitting it.
  defp not_certified(stale, named) do
    sources = Enum.join(stale, ", ")

    %{
      reason:
        "#{named} has not been swept clean at its current commit: #{sources} " <>
          "need a fresh run before this can promote. Nothing was started for " <>
          "you — two ways to get one, and promote again once #{sources} lands:\n\n" <>
          "  - `start_analysis` with the specific source (one call per name in " <>
          "#{sources})\n" <>
          "  - run `mix test` / `mix spex` / `mix credo` / `mix compile` yourself, " <>
          "same as you would to check your own work — the PreToolUse hook routes " <>
          "it through this project's own run ledger, so an ordinary invocation " <>
          "satisfies this gate exactly like a server-dispatched sweep does; " <>
          "nothing extra to call\n\n" <>
          "This refuses where the gate used to wait, sometimes indefinitely: " <>
          "promoting while still editing used to hold this project's lock, " <>
          "refusing every other promotion, for as long as each edit re-staled " <>
          "the sweep the gate was waiting on. A stale source is reported at " <>
          "once instead.",
      stale: stale,
      working_copy: named
    }
  end

  defp gate_result([], _named), do: {:ok, []}

  defp gate_result(problems, named) do
    {:error,
     %{
       reason:
         "#{named} is carrying #{length(problems)} problem(s), so it promotes " <>
           "nothing:\n" <>
           describe(problems) <>
           "\n\nIf #{named} is not this session's own working copy, the gate " <>
           "resolved to a different checkout than the one calling it — fix on " <>
           "that copy, or say so if this looks wrong; a sweep run from here " <>
           "will not touch problems recorded against a different working copy.",
       problems: Enum.map(problems, &problem_key/1),
       working_copy: named
     }}
  end

  # Through `Validation.enforceable/2`, which is what the gate elsewhere blocks
  # on. That function's own doc says why it is public: "two copies of what
  # counts as enforceable drift, and the drift is silent."
  #
  # Credo and compiler findings block at any severity and whatever the stop
  # hook's mode says. A warning let through here lands on main and blocks
  # every other copy's promote until someone cleans it up (v2.0.162's two
  # AliasUsage findings).
  @always_block ~w(credo compiler)

  defp blocking_problems(%Scope{} = scope, copy) do
    here = as_copy(scope, copy)

    strict = ProblemRepository.list_project_problems(here, sources: @always_block)

    here
    |> ProblemRepository.list_project_problems(severity: :error)
    |> Enum.reject(&(&1.source in @always_block))
    |> then(&Validation.enforceable(here, &1))
    |> Kernel.++(strict)
  end

  defp as_copy(%Scope{} = scope, nil), do: scope
  defp as_copy(%Scope{} = scope, %WorkingCopy{id: id}), do: %{scope | active_working_copy_id: id}

  # Always, never conditionally.
  #
  # Whatever would decide "this merge did not need a restart" — no `.ex` files
  # touched, no deps moved — is a second implementation of the code-reloading
  # rules, and when it is wrong the application serves a build nobody can
  # identify while every signal says the promotion completed. Restarting an app
  # that did not need it costs seconds.
  #
  # Dispatched, never awaited (54aa534c, phase two — John: "the deployment
  # should follow async"). `promote/1` answers as soon as the merge lands;
  # the actual deployment — migrations, if the recipe runs them, and the
  # application coming back up — runs in a detached task this call does not
  # wait on.
  #
  # Not optional for a self-hosted checkout: `just restart` kills whatever is
  # listening on :4000, and when that is this very BEAM — the one running the
  # promotion — running it inline takes the promotion's own Task down with
  # it, before it can answer. No exception to catch, no `after` block
  # guaranteed to run: `Promotion.Lock`'s own moduledoc already records that
  # a server restart comes back with an empty lock table, because nothing
  # survives to release it. Dispatching detached is what lets this process
  # answer at all in that case. Doing it unconditionally — for a remote
  # harness too — means one mechanism rather than a path that waits and a
  # path that cannot.
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
  defp restart(%Scope{} = scope, %WorkingCopy{root: root} = running, opts) do
    dispatch_restart(scope, root, running.id, opts)
    {:ok, _} = WorkingCopies.record_preview_status(running, "serving")
    {:error, %{reason: deployment_dispatched_reason()}}
  end

  # Detached rather than linked or awaited: this process may not exist by the
  # time `just restart` returns, and it must not need to for the restart to
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
  defp dispatch_restart(scope, root, working_copy_id, opts) do
    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        scope
        |> Runner.restart(root, working_copy_id)
        |> classify_restart()
        |> verify_unconfirmed(working_copy_id, opts)
        |> log_restart_outcome(root)
        |> tell_the_agent(scope, root, Keyword.get(opts, :notify))
      end)

    :ok
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

    case AppTransport.ensure_app_running(working_copy_id, max(remaining, every)) do
      {:ok, %{status: "serving", commit: commit}} when expected in [nil, commit] ->
        {:confirmed, commit}

      {:ok, %{commit: commit}} when is_binary(commit) ->
        retry_serving(working_copy_id, expected, every, deadline, commit)

      _unreachable_or_down ->
        retry_serving(working_copy_id, expected, every, deadline, seen)
    end
  end

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

  defp log_restart_outcome({:confirmed, revision} = outcome, root) do
    Logger.info(
      "[Promotion] restart confirmed for #{root}, now serving #{revision || "unknown revision"}"
    )

    outcome
  end

  defp log_restart_outcome({:unconfirmed, reason} = outcome, root) do
    Logger.warning("[Promotion] restart for #{root} not confirmed: #{reason}")
    outcome
  end

  defp log_restart_outcome({:failed, reason} = outcome, root) do
    Logger.error(
      "[Promotion] restart FAILED for #{root}, application not confirmed up: #{reason}"
    )

    outcome
  end

  defp log_restart_outcome({:unexpected, other} = outcome, root) do
    Logger.error(
      "[Promotion] restart for #{root} returned something unexpected: #{inspect(other)}"
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
  defp tell_the_agent(outcome, _scope, _root, nil), do: outcome

  defp tell_the_agent({:confirmed, revision} = outcome, scope, root, agent_id) do
    text =
      "The restart from your promotion is confirmed: the application at #{root} " <>
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
  defp tell_the_agent({:failed, reason} = outcome, scope, root, agent_id) do
    text =
      "Correction on the promotion I just reported. The merge landed, but the " <>
        "deployment that followed it failed, so the application at #{root} is NOT " <>
        "serving your work — disregard the part of that message saying QA can " <>
        "start.\n\nWhat went wrong: #{reason}\n\nNothing was rolled back; the merge " <>
        "is still on the running copy. Fix what broke the restart and promote again."

    deliver(scope, agent_id, text, "restart failure")
    outcome
  end

  defp tell_the_agent(outcome, _scope, _root, _agent_id), do: outcome

  # Logged rather than retried, matching `report_to/3`: the agent may already be
  # acting on the first message, and a delivery loop does not fix that.
  defp deliver(scope, agent_id, text, what) do
    case Agents.dispatch_message(scope, agent_id, text) do
      {:ok, disposition, _message} ->
        Logger.info("[Promotion] #{what} #{disposition} to agent #{agent_id}")

      {:error, deliver_error} ->
        Logger.warning(
          "[Promotion] #{what} could not be delivered to agent #{agent_id}: " <>
            inspect(deliver_error)
        )
    end
  end

  defp deployment_dispatched_reason do
    "the restart is dispatched, not awaited: promote answers as soon as the " <>
      "merge lands, and the application restart runs separately. Always, " <>
      "including for a checkout whose own process this restart would " <>
      "otherwise end before it could answer."
  end

  defp describe(problems) do
    problems
    |> Enum.take(10)
    |> Enum.map_join("\n", fn p -> "  #{p.file_path}: #{p.message}" end)
  end

  defp problem_key(p), do: {p.source, p.file_path, p.line, p.message}
end
