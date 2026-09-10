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
      CodeMySpec.Problems,
      CodeMySpec.Requirements,
      CodeMySpec.Users,
      CodeMySpec.Validation,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Environments
  alias CodeMySpec.Problems.ProblemRepository
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
  defp verdict(%WorkingCopy{id: id}, %Scope{active_working_copy_id: id}),
    do: {true, %{status: "Working on the running copy"}}

  defp verdict(%WorkingCopy{}, %Scope{active_working_copy_id: nil}),
    do: {true, %{status: "No checkout on this scope"}}

  defp verdict(%WorkingCopy{}, %Scope{active_working_copy_id: here}) do
    case WorkingCopies.fetch(here) do
      {:ok, copy} -> in_sync(copy)
      _ -> {true, %{status: "This checkout is not on file"}}
    end
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
    |> sync_verdict()
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

  defp sync_verdict([]), do: {true, %{status: "In sync with main, tree clean"}}

  defp sync_verdict(reasons) do
    {false,
     %{
       reason:
         "this checkout and main have diverged, so QA would not test what you " <>
           "wrote: " <> Enum.join(Enum.reverse(reasons), "; ") <> ".",
       out_of_sync: reasons
     }}
  end

  # -------------------------------------------------------------- the promotion

  @doc """
  Gate, merge, restart, and report what the application is serving.

  Refuses rather than half-finishes. Every refusal names the thing the agent
  has to act on — the problem holding the gate, the file that conflicts, the
  work it has not committed — because a refusal an agent cannot act on stops
  the pipeline just as surely as a bug.
  """
  @spec promote(Scope.t()) :: {:ok, map()} | {:error, map()}
  def promote(%Scope{} = scope) do
    with {:ok, running} <- running_copy(scope),
         {:ok, from} <- promoting_copy(scope, running),
         :ok <- refuse_uncommitted(scope, from),
         {:ok, swept} <- gate(scope),
         {:ok, branch} <- current_branch(scope, from),
         carried_before <- blocking_problems(scope, running),
         :ok <- merge(scope, running, branch),
         :ok <- gate_target(scope, running, carried_before),
         {:ok, serving} <- restart(scope, running) do
      {:ok,
       %{
         merged: branch,
         into: running.root,
         serving: serving,
         swept: swept
       }}
    end
  end

  @doc """
  Start a promotion and report the outcome back to the agent that asked.

  For callers that have somewhere to be told: an Alloy agent has a conversation,
  so the tool call returns at once and the result arrives as a message.

  A promotion sweeps analyzers before it will call a copy clean, and a sweep is
  minutes. Holding a tool call open for that is the wrong shape twice over — the
  agent is blocked with no output, and it cannot tell a slow sweep from a hung
  one. Started-then-told is what the work actually looks like.

  The task is supervised, and its result reaches the agent through
  `Agents.message_agent/4` — which wakes it, which is the point.
  """
  @spec promote_async(Scope.t(), Ecto.UUID.t()) :: :ok
  def promote_async(%Scope{} = scope, agent_id) when is_binary(agent_id) do
    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        scope
        |> promote()
        |> report_to(scope, agent_id)
      end)

    :ok
  end

  defp report_to(result, %Scope{} = scope, agent_id) do
    case Agents.message_agent(scope, agent_id, outcome_text(result)) do
      {:ok, _reply} ->
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

  defp outcome_text({:ok, %{merged: branch, serving: %{revision: revision}}}) do
    "Your promotion finished. #{branch} is on the running dev copy and the " <>
      "application is serving #{revision || "the merged code"}. QA on these " <>
      "stories will now test what you wrote."
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

  defp promoting_copy(%Scope{active_working_copy_id: id}, %WorkingCopy{id: id}) do
    {:error,
     %{
       reason:
         "this is the running copy — its work is already where a promotion " <>
           "would put it, and there is nothing to merge."
     }}
  end

  defp promoting_copy(%Scope{active_working_copy_id: id}, _running) when is_binary(id) do
    case WorkingCopies.fetch(id) do
      {:ok, %WorkingCopy{root: root} = copy} when is_binary(root) -> {:ok, copy}
      _ -> {:error, %{reason: "this checkout has not reported where it is."}}
    end
  end

  defp promoting_copy(%Scope{}, _running),
    do: {:error, %{reason: "no working copy on this scope; nothing to promote."}}

  # Refused before the merge rather than cleaned up after: an aborted
  # half-merge leaves the running checkout in a state nobody asked for, and the
  # agent then has two problems instead of one.
  defp refuse_uncommitted(%Scope{} = scope, %WorkingCopy{root: root}) do
    case git(scope, root, ["status", "--porcelain"]) do
      {"", 0} ->
        :ok

      {dirty, 0} ->
        {:error,
         %{
           reason: "this copy has uncommitted work. Commit it, then promote.",
           dirty: String.trim_trailing(dirty)
         }}

      {out, _} ->
        {:error, %{reason: "could not read this checkout's state: #{String.trim(out)}"}}
    end
  end

  # A stale analyzer is swept, not refused.
  #
  # "No problems recorded" and "no problems" are different claims, and the gap
  # between them is the whole value of the gate: a copy whose analyzers last ran
  # before the agent's final commits has an empty problem list that means
  # nothing. Refusing would hand the agent a state it cannot clear — it cannot
  # make an analyzer fresh by waiting — so the gate waits for a fresh answer
  # instead.
  defp gate(%Scope{} = scope) do
    %{enqueued: enqueued} = sweep_stale(scope)

    scope
    |> blocking_problems(nil)
    |> gate_known(scope, enqueued)
  end

  # Problems already recorded answer immediately; only a *clean* result has to
  # wait for the sweep.
  #
  # The order matters. A sweep cannot make a recorded problem go away except by
  # re-running and not finding it, and meanwhile the agent has a list it can act
  # on right now. Waiting first would hold that list behind minutes of analysis
  # to tell the agent something it could have been told at once.
  #
  # It is the empty list that is untrustworthy: "no problems recorded" and "no
  # problems" are different claims, and the gap between them is the whole value
  # of the gate.
  defp gate_known([], scope, enqueued), do: certify_clean(scope, enqueued)
  defp gate_known(problems, _scope, enqueued), do: gate_result(problems, enqueued)

  defp certify_clean(%Scope{} = scope, enqueued) do
    case Analysis.await_all(scope, timeout: sweep_timeout()) do
      :ok -> scope |> blocking_problems(nil) |> gate_result(enqueued)
      :timeout -> still_sweeping(enqueued)
    end
  end

  # Bounded, and a refusal rather than a longer wait.
  #
  # `Analysis.await_all/2` defaults to ten minutes, which is right for a
  # background reconcile and wrong here: this runs inside a tool call, and an
  # agent blocked for ten minutes with no output cannot tell a slow sweep from
  # a hung one. Refusing keeps the sweep running — it was dispatched before we
  # waited — so retrying shortly after finds it fresh, and the agent has
  # something to do in the meantime.
  # `only_failed: true`, which does not mean what its name suggests here.
  #
  # The default re-enqueues *everything* by design — "a stop with changed files
  # re-runs everything", because a skipped source leaves last run's problems in
  # place with no run to explain them (`analysis.ex:151`). Right for a stop;
  # wrong for a gate, which would then force a full sweep on every promotion
  # and wait for it even when every analyzer is already current.
  #
  # The flag selects `stale?/3` instead, so only stale or never-run sources are
  # enqueued — and "a source that has never run is stale, not current", so a
  # fresh copy still gets swept. That is criterion 3166 exactly.
  defp sweep_stale(%Scope{} = scope),
    do: Analysis.ensure_stale_runs(scope, Run.sources(), only_failed: true)

  defp still_sweeping(enqueued) do
    {:error,
     %{
       reason:
         "the gate is waiting on a fresh analyzer sweep" <>
           sweep_names(enqueued) <>
           ". Nothing was merged. The sweep is still running — promote again " <>
           "shortly and it will answer against fresh results.",
       sweeping: enqueued
     }}
  end

  defp sweep_names([]), do: ""
  defp sweep_names(sources), do: " (" <> Enum.join(sources, ", ") <> ")"

  defp sweep_timeout,
    do: Application.get_env(:code_my_spec, :promotion_sweep_timeout, :timer.minutes(2))

  defp gate_result([], enqueued), do: {:ok, enqueued}

  defp gate_result(problems, _enqueued) do
    {:error,
     %{
       reason:
         "this copy is carrying #{length(problems)} problem(s), so it promotes " <>
           "nothing:\n" <> describe(problems),
       problems: Enum.map(problems, &problem_key/1)
     }}
  end

  # The bar is "the merge added no problems", not "the target is clean".
  #
  # The second makes every promotion hostage to work from other epics, and this
  # graph has had four gates of that shape removed from it already. A gate whose
  # passing state depends on work outside the gated unit is a wall.
  defp gate_target(%Scope{} = scope, %WorkingCopy{} = running, carried_before) do
    known = MapSet.new(carried_before, &problem_key/1)

    there = as_copy(scope, running)
    %{} = sweep_stale(there)

    case Analysis.await_all(there, timeout: sweep_timeout()) do
      :ok ->
        scope
        |> blocking_problems(running)
        |> Enum.reject(&MapSet.member?(known, problem_key(&1)))
        |> target_result()

      # The merge has already landed, so this is not "nothing happened" — say
      # so plainly rather than reporting a clean promotion we cannot vouch for.
      :timeout ->
        {:error,
         %{
           reason:
             "the merge landed, but the sweep verifying it did not finish in " <>
               "time. The running copy has the work; whether the merge added " <>
               "problems is not yet known. Promote again to re-check."
         }}
    end
  end

  defp target_result([]), do: :ok

  defp target_result(added) do
    {:error,
     %{
       reason:
         "the merge landed but left the running copy carrying " <>
           "#{length(added)} problem(s) it did not carry before:\n" <> describe(added),
       added: Enum.map(added, &problem_key/1)
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

  defp current_branch(%Scope{} = scope, %WorkingCopy{root: root}) do
    case git(scope, root, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {branch, 0} -> {:ok, String.trim(branch)}
      {out, _} -> {:error, %{reason: "could not read this checkout's branch: #{out}"}}
    end
  end

  # A conflict is a question about intent, and the agent that wrote one side is
  # the only party holding the answer. So this does not guess, and does not
  # `--abort` either: the conflict stays in the running checkout where it can be
  # resolved. Aborting would be the tidier-looking failure and the worse one —
  # the agent is told "promotion failed", finds a clean tree, and has nothing to
  # work on.
  defp merge(%Scope{} = scope, %WorkingCopy{root: root}, branch) do
    case git(scope, root, ["merge", "--no-edit", branch]) do
      {_out, 0} -> :ok
      {out, _} -> conflict(scope, root, branch, out)
    end
  end

  defp conflict(%Scope{} = scope, root, branch, out) do
    {status, _} = git(scope, root, ["status", "--porcelain"])

    conflicted =
      status
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.match?(&1, ~r/^(UU|AA|DD|AU|UA|DU|UD)/))
      |> Enum.map(&(&1 |> String.slice(3..-1//1) |> String.trim()))

    {:error,
     %{
       reason:
         "merging #{branch} into the running copy conflicts" <>
           conflict_files(conflicted) <>
           ". The conflict is left in #{root} for you to resolve.",
       conflicts: conflicted,
       output: String.trim(out)
     }}
  end

  defp conflict_files([]), do: ""
  defp conflict_files(files), do: " in " <> Enum.join(files, ", ")

  # Always, never conditionally.
  #
  # Whatever would decide "this merge did not need a restart" — no `.ex` files
  # touched, no deps moved — is a second implementation of the code-reloading
  # rules, and when it is wrong the application serves a build nobody can
  # identify while every signal says the promotion completed. Restarting an app
  # that did not need it costs seconds.
  defp restart(%Scope{} = scope, %WorkingCopy{root: root}) do
    scope.environment
    |> Environments.exec_file_exists?(Path.join(root, "justfile"))
    |> run_restart(scope, root)
  end

  defp run_restart(false, _scope, root) do
    {:error,
     %{
       reason:
         "#{root} has no justfile, so there is no `just restart` to bring the " <>
           "application back up on the merged code. The merge is done; the app " <>
           "is still serving what it was."
     }}
  end

  # `stderr_to_stdout: true`, and it is the difference between a refusal an
  # agent can act on and one it cannot.
  #
  # Compilers, migrations and the shell all write their failures to stderr.
  # Without this the promotion caught a broken build correctly — non-zero exit,
  # nothing merged onward — and then reported "`just restart` failed (1):" with
  # an empty body, telling the agent its promotion failed and not one word about
  # what broke.
  defp run_restart(true, %Scope{} = scope, root) do
    case Environments.cmd(scope.environment, "just", ["restart"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} -> serving(scope, root, out)
      {out, code} -> {:error, %{reason: "`just restart` failed (#{code}):\n#{String.trim(out)}"}}
    end
  end

  defp serving(%Scope{} = scope, root, out) do
    case git(scope, root, ["rev-parse", "--short", "HEAD"]) do
      {sha, 0} -> {:ok, %{revision: String.trim(sha), output: String.trim(out)}}
      {_, _} -> {:ok, %{revision: nil, output: String.trim(out)}}
    end
  end

  # An explicit `:cd` beats the environment's own cwd, which is what lets one
  # environment drive both checkouts.
  defp git(%Scope{environment: env}, root, args),
    do: Environments.cmd(env, "git", args, cd: root, stderr_to_stdout: true)

  defp describe(problems) do
    problems
    |> Enum.take(10)
    |> Enum.map_join("\n", fn p -> "  #{p.file_path}: #{p.message}" end)
  end

  defp problem_key(p), do: {p.source, p.file_path, p.line, p.message}
end
