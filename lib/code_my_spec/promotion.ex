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
      CodeMySpec.BootVersion,
      CodeMySpec.Environments,
      CodeMySpec.Problems,
      CodeMySpec.Requirements,
      CodeMySpec.Users,
      CodeMySpec.Utils,
      CodeMySpec.Validation,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.BootVersion
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Problems.ProblemRepository
  alias CodeMySpec.Promotion.Lock
  alias CodeMySpec.Promotion.Runner
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy

  # ----------------------------------------------------------------- read model

  @doc """
  The requirement-graph checker: `{satisfied?, details}`.

  Answers from git state, not from files.

  The version before this compared the story's implementation files against the
  running copy's, and it was insufficient for a case that happens on every
  project: promote a story, QA files an issue, fix the issue on the working
  copy. Whether the fix is back on main is a question about commits, and asking
  it about files means depending on scans landing, on story-to-component
  linkage, and on roles being classified right — three ways to answer "yes" for
  a checkout that is behind.

  Three conditions, all of them the checkout's own report:

    * nothing on this checkout that main does not have
    * nothing on main that this checkout does not have
    * no uncommitted changes

  A worktree shares an object store with the checkout it was made from, so all
  three are answerable from the copy alone. The machine that holds the disk
  measures them on every sync — the server has no `git` to run, and a graph
  computed inside the channel process cannot ask the channel.

  Per copy rather than per story. Every story on a checkout gets the same
  answer, because the checkout is what is or is not in sync — which is also why
  this costs one column read rather than a walk.
  """
  @spec running_copy_check(Scope.t(), term()) :: {boolean(), map()}
  def running_copy_check(%Scope{} = scope, _entity) do
    scope
    |> WorkingCopies.main()
    |> verdict(scope)
  end

  # No copy is designated, so nothing is running and nothing can be behind it.
  # Holding every story until somebody designates one would be a wall with no
  # agent able to clear it.
  defp verdict(nil, _scope), do: {true, %{status: "No running copy designated"}}

  # Working directly on the running copy. There is no branch to merge and
  # nothing an agent could do to a gate that asked for one — John: "it is
  # eminently possible that someone would be just doing the work on Maine."
  #
  # Still has to be serving. The code is here by definition; whether anything
  # is answering is a separate question and QA needs both.
  defp verdict(%WorkingCopy{id: id} = running, %Scope{active_working_copy_id: id}),
    do: serving(running, %{status: "Working on the running copy"})

  defp verdict(%WorkingCopy{}, %Scope{active_working_copy_id: nil}),
    do: {true, %{status: "No checkout on this scope"}}

  defp verdict(%WorkingCopy{} = running, %Scope{active_working_copy_id: here}) do
    case WorkingCopies.fetch(here) do
      {:ok, copy} -> copy |> in_sync() |> and_serving(running)
      _ -> {true, %{status: "This checkout is not on file"}}
    end
  end

  # Both halves, and the order matters: naming the sync problem first gives an
  # agent something it can act on before it is told the application is down.
  #
  # This used to say promoting fixes both, which is true for *ahead* and false
  # for *behind*: promotion merges this branch into the running copy and leaves
  # this worktree where it was, so promoting while behind restarts the shared
  # dev server and leaves the agent exactly as far behind. The counts now travel
  # with the verdict so the remedy can tell those cases apart.
  defp and_serving({false, _details} = behind, _running), do: behind
  defp and_serving({true, details}, running), do: serving(running, details)

  # Whether the application QA browses is answering.
  #
  # `code_on_running_copy` proved the code was on the running copy and stopped
  # there, and the two came apart within a day: Broken Oaths' preview was down,
  # this gate was satisfied, and a QA agent stood in front of a connection
  # refused with the graph reporting the story ready to test. It then asked to
  # restart the app itself — which would have started it on code that did not
  # contain the work it was there to verify.
  #
  # Never checked passes. A copy with no preview address has nothing to be up,
  # and a harness that has not reported yet is not evidence of anything; holding
  # every story on either would be a gate no agent can clear.
  defp serving(%WorkingCopy{preview_status: nil}, details), do: {true, details}
  defp serving(%WorkingCopy{preview_status: "serving"}, details), do: {true, details}

  # A 500 is the application answering. That is a QA finding rather than a
  # reason to keep QA away from it — the whole point of testing is to meet it.
  defp serving(%WorkingCopy{preview_status: "erroring"}, details), do: {true, details}

  defp serving(%WorkingCopy{preview_status: "down"} = running, _details) do
    {false,
     %{
       reason:
         "the application is not answering at #{running.preview_url || "its preview address"}, " <>
           "so there is nothing for QA to test. `promote` restarts it — and if this " <>
           "checkout is also behind, brings the work across in the same act.",
       preview_status: "down"
     }}
  end

  # Never reported is not the same as in sync, and saying so is the difference
  # between a gate an agent can clear and one it cannot see.
  defp in_sync(%WorkingCopy{git_state_at: nil}) do
    {false,
     %{
       reason:
         "this checkout has not reported whether its work is on main. Its " <>
           "harness reports that on every sync; if this persists, the harness " <>
           "is not serving this copy."
     }}
  end

  defp in_sync(%WorkingCopy{} = copy) do
    copy
    |> out_of_sync_reasons()
    |> sync_verdict(copy)
  end

  defp out_of_sync_reasons(%WorkingCopy{} = copy) do
    []
    |> behind_reason(copy.commits_behind_main)
    |> ahead_reason(copy.commits_ahead_of_main)
    |> dirty_reason(copy.tree_dirty)
  end

  defp ahead_reason(reasons, n) when is_integer(n) and n > 0,
    do: ["#{n} commit(s) here are not on main — promote them" | reasons]

  defp ahead_reason(reasons, _), do: reasons

  defp behind_reason(reasons, n) when is_integer(n) and n > 0,
    do: ["#{n} commit(s) on main are not here — merge main in first" | reasons]

  defp behind_reason(reasons, _), do: reasons

  defp dirty_reason(reasons, true), do: ["uncommitted changes — commit them" | reasons]
  defp dirty_reason(reasons, _), do: reasons

  defp sync_verdict([], _copy), do: {true, %{status: "In sync with main, tree clean"}}

  # The counts travel with the sentence, because "behind only" is a materially
  # different situation from the others and the reader cannot tell from the
  # prose. Promotion merges this branch *into* the running copy and leaves this
  # worktree where it was, so the state immediately after a successful promotion
  # is behind-only — and the remedy there is to merge main in here, not to
  # promote again. Told to promote, an agent restarts the shared dev server for
  # nothing and is no less behind afterwards.
  defp sync_verdict(reasons, %WorkingCopy{} = copy) do
    {false,
     %{
       reason:
         "this checkout and main have diverged, so QA would not test what you " <>
           "wrote: " <> Enum.join(Enum.reverse(reasons), "; ") <> ".",
       out_of_sync: reasons,
       behind: copy.commits_behind_main || 0,
       ahead: copy.commits_ahead_of_main || 0,
       dirty: copy.tree_dirty == true
     }}
  end

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
  """
  @spec promote(Scope.t()) :: {:ok, map()} | {:error, map()}
  def promote(%Scope{} = scope) do
    with {:ok, running} <- running_copy(scope) do
      Lock.with_lock(running.project_id, fn -> promote_into(scope, running) end)
      |> unlocked()
    end
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
  # No gate and no sweep, because a restart carries no code. `gate/1` exists to
  # stop a merge putting failing work in front of QA; nothing crosses here, so
  # there is nothing to certify and no reason to spend minutes of analyzer sweep
  # before a dead application comes back.
  defp promote_into(%Scope{active_working_copy_id: id} = scope, %WorkingCopy{id: id} = running) do
    # No merge crossed here, so there is no range to ask `contract_changed?/2`
    # about — the current commit could still differ from what the harness
    # booted, same as any ordinary push. Always refresh: the only caller that
    # gets to skip it is the one that has already checked.
    #
    # `restart/3` always answers `{:error, %{reason: ...}}` now — dispatched,
    # not awaited, for every promotion (54aa534c) — so this wraps it as the
    # success it is rather than pattern-matching for a confirmation that no
    # longer arrives.
    {:error, reason} = restart(scope, running, true)
    {:ok, %{restarted: running.root, serving: %{unconfirmed: reason}}}
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
  defp promote_into(%Scope{} = scope, running) do
    with {:ok, from} <- promoting_copy(scope, running),
         {:ok, %{branch: branch} = pre} <- Runner.precheck(scope, from.root, from.id),
         {:ok, swept} <- gate(scope),
         {:ok, merge_result} <- Runner.merge(scope, running.root, branch, from.id) do
      scope
      |> restart(running, refresh_harness?(scope, merge_result))
      |> merged(branch, running, swept, Map.get(pre, :untracked, []))
    end
  end

  # Whether the restart that follows this merge needs to rebuild the harness
  # too — the other half of `just refresh` that `just restart` always ran
  # unconditionally, on every promotion, whether or not the merge touched
  # anything the harness cares about (376e3356).
  #
  # Answered from the merge's own `before`/`after` — the checkout's HEAD on
  # either side of exactly the commits this promotion just brought in — rather
  # than the harness's general drift, which would also be true for commits
  # this promotion had nothing to do with.
  #
  # `false` is the only answer that changes anything: `:unknown` (the range
  # could not be read) and `true` both keep today's behavior. That asymmetry
  # is deliberate. A refresh this promotion did not need costs a shared
  # harness bounce and some seconds; a refresh it did need and skipped is
  # d00a3272 again — every stop hook on the machine wrong until someone
  # notices and restarts it by hand. Only a merge whose range is *provably*
  # silent on `lib/cms_harness` and the channel modules gets to skip it.
  #
  # Scoped to a local promotion on purpose. `BootVersion.contract_changed?/2`
  # reads the diff against *this process's own* booted root — correct only
  # when that root is the same checkout the merge just landed in, which is
  # true for this project's own self-hosted setup but not guaranteed for a
  # `:harness`-environment promotion, whose checkout lives on a different
  # machine than the server answering this question. Rather than guess, a
  # harness-environment promotion always refreshes, unchanged from before.
  defp refresh_harness?(%Scope{environment: %Environment{type: :harness}}, _merge_result),
    do: true

  defp refresh_harness?(%Scope{}, %{before: before, after: after_})
       when is_binary(before) and is_binary(after_) do
    case BootVersion.contract_changed?(before, after_) do
      false -> false
      _ -> true
    end
  end

  defp refresh_harness?(%Scope{}, _merge_result), do: true

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
  defp merged({:error, reason}, branch, running, swept, untracked) do
    reason
    |> restart_acknowledgement_lost?()
    |> unconfirmed(reason, branch, running, swept, untracked)
  end

  defp unconfirmed(true, reason, branch, running, swept, untracked) do
    {:ok,
     %{
       merged: branch,
       into: running.root,
       serving: %{revision: nil, unconfirmed: reason},
       swept: swept,
       untracked: untracked
     }}
  end

  defp unconfirmed(false, reason, _branch, _running, _swept, _untracked), do: {:error, reason}

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

  @doc """
  Start a promotion and report the outcome back to the agent that asked.

  `agent_id` is who to tell, and `nil` is nobody. An Alloy agent has a
  conversation, so the result arrives there as a message; every other caller —
  a Claude Code session, a script, a person with curl — gets the outcome in the
  log and confirms by asking what the application is serving. The work is the
  same either way, which is why having nowhere to be messaged is not a reason
  to make the caller wait.

  A promotion sweeps analyzers before it will call a copy clean, and a sweep is
  minutes. Holding a tool call open for that is the wrong shape twice over — the
  agent is blocked with no output, and it cannot tell a slow sweep from a hung
  one. Started-then-told is what the work actually looks like.

  The task is supervised, and its result reaches the agent through
  `Agents.message_agent/4` — which wakes it, which is the point.
  """
  @spec promote_async(Scope.t(), Ecto.UUID.t() | nil) :: :ok
  def promote_async(%Scope{} = scope, agent_id) when is_binary(agent_id) or is_nil(agent_id) do
    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        scope
        |> promote()
        |> report_to(scope, agent_id)
      end)

    :ok
  end

  # Written down before it is delivered, and that ordering is the point.
  #
  # A promotion runs in a supervised task and reports through one channel: a
  # message to the agent. So every way that channel can fail — the agent busy,
  # the call timing out, the task dying between the work and the telling — ends
  # with nobody knowing anything. There is no second place to look, because
  # until now there was no first one.
  #
  # Measured: a promotion refused on 192 credo problems, correctly, and twelve
  # minutes later the agent had not been told, the conversation held no outcome,
  # and `web.log` held nothing between the gate reconciling and silence. The
  # refusal was right and completely invisible.
  #
  # The log line costs nothing and answers "what did it decide" independently of
  # whether anyone received it.
  #
  # `dispatch_message/3`, not `message_agent/4`. The latter runs the agent's
  # whole turn inside a `GenServer.call` and waits for it, so a promotion that
  # finished parked itself behind however long the agent felt like working —
  # and an agent that had just been told to go and fix 28 credo problems is
  # exactly the one that will not come back soon. Watched: the refusal was
  # computed and logged at 02:45:55 and had still not reached the conversation
  # eleven minutes later, with no error anywhere, because the task was sitting
  # in that call.
  #
  # `dispatch_message/3` answers `:started` or `:queued` as soon as the machine
  # has taken it, and records the message on the conversation either way, which
  # is the whole of what reporting an outcome needs. The dev tools' own message
  # route defaults to the same non-waiting shape for the same reason.
  # No agent to tell, which is every caller that is not one of our own agents —
  # a Claude Code session, a script, a person with curl. The work is identical
  # and only the telling is missing, so the log line above is the whole report.
  #
  # This clause is what lets `promote` be a sink for everybody. It used to
  # refuse a connection with no agent and point at `promote_sync`, which waits
  # for a gate, a merge, an analyzer sweep and a restart — minutes — over a
  # transport that gives up in thirty seconds. So the one caller told to use the
  # blocking tool was the one that could never survive it, and a promotion that
  # succeeded came back as a timeout.
  defp report_to(result, %Scope{} = _scope, nil) do
    Logger.info(
      "[Promotion] #{outcome_label(result)} (no agent to tell): #{outcome_text(result)}"
    )

    :ok
  end

  defp report_to(result, %Scope{} = scope, agent_id) do
    Logger.info(
      "[Promotion] #{outcome_label(result)} for agent #{agent_id}: #{outcome_text(result)}"
    )

    case Agents.dispatch_message(scope, agent_id, outcome_text(result)) do
      {:ok, disposition, _message} ->
        Logger.info("[Promotion] outcome #{disposition} to agent #{agent_id}")
        :ok

      # The promotion already happened; only the telling failed. Logged rather
      # than retried, because a second delivery of a result the agent may
      # already have acted on is worse than a log line.
      {:error, reason} ->
        Logger.warning(
          "[Promotion] finished but could not tell agent #{agent_id}: #{inspect(reason)}"
        )
    end
  end

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
  defp outcome_text({:ok, %{merged: branch, serving: %{unconfirmed: _}}}) do
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
  defp outcome_text({:ok, %{restarted: root, serving: %{unconfirmed: _}}}) do
    "Your promotion finished. There was nothing to merge — you are working on " <>
      "the running copy — so the application at #{root} is restarting now in " <>
      "the background, not waited on. Do not promote again just to check; ask " <>
      "what is serving instead."
  end

  defp outcome_text({:error, %{reason: reason}}),
    do: "Your promotion did not go through. #{reason}"

  defp outcome_text(other),
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
  defp gate(%Scope{} = scope) do
    scope
    |> blocking_problems(nil)
    |> gate_known(scope)
  end

  # A problem already recorded answers immediately, staleness or not — a real
  # finding does not stop being real because the run that found it is not the
  # newest one. Only an *empty* list needs the staleness check, because an
  # empty list from a stale run is not evidence of anything: "no problems
  # recorded" and "no problems" are different claims, and closing that gap
  # used to mean waiting for a fresh run — it now means reading whether one
  # already exists.
  defp gate_known([], scope), do: gate_freshness(stale_sources(scope))
  defp gate_known(problems, _scope), do: gate_result(problems)

  defp gate_freshness([]), do: {:ok, []}
  defp gate_freshness(stale), do: {:error, not_certified(stale)}

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
  defp not_certified(stale) do
    named = Enum.join(stale, ", ")

    %{
      reason:
        "this copy has not been swept clean at its current commit: #{named} " <>
          "need a fresh run before this can promote. Nothing was started for " <>
          "you — run analysis on #{named} (a stop hook does this on its own; " <>
          "`start_analysis` runs one directly) and promote again once it " <>
          "lands.\n\n" <>
          "This refuses where the gate used to wait, sometimes indefinitely: " <>
          "promoting while still editing used to hold this project's lock, " <>
          "refusing every other promotion, for as long as each edit re-staled " <>
          "the sweep the gate was waiting on. A stale source is reported at " <>
          "once instead.",
      stale: stale
    }
  end

  defp gate_result([]), do: {:ok, []}

  defp gate_result(problems) do
    {:error,
     %{
       reason:
         "this copy is carrying #{length(problems)} problem(s), so it promotes " <>
           "nothing:\n" <> describe(problems),
       problems: Enum.map(problems, &problem_key/1)
     }}
  end

  # Through `Validation.enforceable/2`, which is what the gate elsewhere blocks
  # on. That function's own doc says why it is public: "two copies of what
  # counts as enforceable drift, and the drift is silent."
  defp blocking_problems(%Scope{} = scope, copy) do
    here = as_copy(scope, copy)

    here
    |> ProblemRepository.list_project_problems(severity: :error)
    |> then(&Validation.enforceable(here, &1))
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
  defp restart(%Scope{} = scope, %WorkingCopy{root: root} = running, refresh_harness?) do
    dispatch_restart(scope, root, running.id, refresh_harness?)
    {:ok, _} = WorkingCopies.record_preview_status(running, "serving")
    {:error, %{reason: deployment_dispatched_reason()}}
  end

  # Detached rather than linked or awaited: this process may not exist by the
  # time `just restart` returns, and it must not need to for the restart to
  # have happened. `CodeMySpec.TaskSupervisor` is the same one `promote_async/2`
  # already reports through for the same reason — fire, do not wait.
  defp dispatch_restart(scope, root, working_copy_id, refresh_harness?) do
    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        Runner.restart(scope, root, working_copy_id, refresh_harness?)
      end)

    :ok
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
