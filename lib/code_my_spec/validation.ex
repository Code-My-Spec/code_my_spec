defmodule CodeMySpec.Validation do
  @moduledoc """
  Orchestrates stop hook validation: file sync, in-process validators, and the
  blocking decision. A stop never starts, ingests or waits on a subprocess
  analyzer (compile, credo, tests, spex); it decides from the Problems that
  completed `Analysis` runs already persisted.

  The blocking decision consults `ProjectConfiguration` modes per source:

  - `:off` — source never blocks (matches `resolve_analyzers` filtering)
  - `:block_all` — every problem from this source blocks
  - `:block_changed` — only problems on files/components changed during the
    task block; others are advisory
  - `:dont_block` — problems are persisted but never block

  Before the mode applies, `Validation.Blocking.split_by_story_enforcement/3`
  makes unlocated spex findings advisory; every located red spex is enforced.
  Advisory-severity findings, and spex for roles that hold no problems, are
  then moved to advisory.

  The blocking check runs even when no files changed this turn — outstanding
  problems from a prior run still apply.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Stories,
      CodeMySpec.Agents.RoleProfile,
      CodeMySpec.Analysis,
      CodeMySpec.Configurations,
      CodeMySpec.FileEdits,
      CodeMySpec.Files,
      CodeMySpec.Problems,
      CodeMySpec.Sessions,
      CodeMySpec.StaticAnalysis,
      CodeMySpec.Users.Scope,
      CodeMySpec.Validation.Blocking,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  require Logger

  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Configurations
  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Problems
  alias CodeMySpec.Sessions
  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.StaticAnalysis.CredoRun
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation.Blocking
  alias CodeMySpec.WorkingCopies

  # Analyzer atoms that execute as mix subprocesses → their Analysis source.
  # A stop runs only the rest (the in-process validators).
  @subprocess_analyzers %{credo: "credo", exunit_stale: "exunit", spex_stale: "spex"}

  # Configurable source → {ProjectConfiguration field, scope predicate for
  # :block_changed mode}.
  @configurable_sources %{
    "credo" => {:credo, :by_file_path},
    "exunit" => {:exunit, :by_component_id},
    "spex" => {:spex, :by_file_path},
    "qa_validation" => {:qa_validation, :by_file_path},
    "architecture" => {:architecture, :by_component_id}
  }

  @doc """
  Run the full validation pipeline for a stop hook.

  Returns `{:ok, %{changed_files:, analysis:, advisory_note:}}` when nothing
  blocks, or `{:error, reason, blocking_key}` when the blocking check rejects.

  ## Options

  - `:session_id` - external session id; when present, the changed-file
    set is intersected with PostToolUse-attributed edits for this
    `(session_id, agent_id)`. Problems on files attributed elsewhere
    are excluded from the block decision.
  - `:agent_id` - sub-agent id; nil means the main agent. Combined with
    `:session_id` for the FileEdits attribution lookup.

  A stop never starts, ingests or waits on analysis; it reads what runs already
  persisted. A spec that needs findings lands them as an analysis run first, and
  only then stops.
  """
  @spec validate_stop(Scope.t(), map() | nil, keyword()) ::
          {:ok, %{changed_files: [map()], analysis: map()}}
          | {:error, String.t(), String.t() | nil}
  def validate_stop(%Scope{} = scope, task, opts \\ []) do
    start = System.monotonic_time(:millisecond)

    result = do_validate_stop(scope, task, opts)

    elapsed = System.monotonic_time(:millisecond) - start
    Logger.info("[Validation] validate_stop completed in #{elapsed}ms")

    result
  end

  # No project bound yet — a stop hook firing before `init_project`. There is
  # nothing to check and nothing to check it against.
  defp do_validate_stop(%Scope{active_project_id: nil}, _task, _opts) do
    {:ok, %{changed_files: [], analysis: %{enqueued: [], memoized: []}}}
  end

  # No working copy on this machine: ask the harness that holds this project.
  # Only when none does is there nothing to check against.
  defp do_validate_stop(%Scope{cwd: nil} = scope, task, opts) do
    case Analysis.remote_executor(scope) do
      {:ok, _harness} ->
        remote_validate_stop(scope, task, opts)

      :none ->
        {:ok, %{changed_files: [], analysis: %{enqueued: [], memoized: []}}}
    end
  end

  defp do_validate_stop(%Scope{cwd: cwd} = scope, task, opts) do
    case FileSync.sync_changed(scope, base_dir: cwd) do
      {:ok, sync_result} -> local_validate_stop(scope, task, opts, cwd, sync_result)
      {:error, {:cannot_scan, _}} -> do_validate_stop(%{scope | cwd: nil}, task, opts)
    end
  end

  # `cwd` is set for any resolved scope, including on the server where no local
  # environment can scan the checkout. A sync that cannot scan falls back to the
  # `cwd: nil` path rather than answering from a walk that never happened.
  defp local_validate_stop(%Scope{} = scope, task, opts, cwd, sync_result) do
    FileComponentSync.sync_from_files(scope,
      base_dir: cwd,
      changed_paths: sync_result.changed_paths,
      removed_module_names: sync_result.removed_module_names
    )

    # An agent with no session names its own changed set. The scan's dirty list
    # cannot stand in for it: by turn end the file just written has usually been
    # synced already and is no longer dirty.
    all_changed =
      case agent_changed_files(scope, opts) do
        [] -> resolve_changed_files(scope, task, sync_result)
        edited -> edited
      end

    changed_files = filter_by_session_attribution(all_changed, scope, cwd, task, opts)

    config = Configurations.get_or_create(scope)

    analysis = run_pipeline(scope, task, changed_files, config, opts)

    with {:ok, note} <-
           check_blocking_problems(scope, changed_files, all_changed != [], config, opts) do
      {:ok, %{changed_files: changed_files, analysis: analysis, advisory_note: note}}
    end
  end

  # The same pipeline minus the two steps that need a disk here: the harness has
  # already reconciled its manifest (so File rows are current), and in-process
  # validators read file contents, which never cross the wire. The decision is
  # identical; only where the files were read differs.
  defp remote_validate_stop(scope, task, opts) do
    {changed_files, consume_ledger} = remote_changed_files(scope, task, opts)
    config = Configurations.get_or_create(scope)
    project_changed? = project_changed?(scope, task)

    analysis = run_pipeline(scope, task, changed_files, config, opts)

    with {:ok, note} <-
           check_blocking_problems(scope, changed_files, project_changed?, config, opts) do
      # Consume the ledger only after both of this stop's reads of it (here and
      # inside `check_blocking_problems/5`) have been acted on.
      consume_ledger.()
      {:ok, %{changed_files: changed_files, analysis: analysis, advisory_note: note}}
    end
  end

  # Did anything in the project move while this task ran, before attribution
  # narrows anything. `changed_files` cannot answer it: it says no exactly when
  # attribution is broken. Without a task there is no window, so the answer is
  # "no independent evidence".
  defp project_changed?(scope, %{started_at: started_at}) when not is_nil(started_at),
    do: Files.changed_since(scope, started_at) != []

  defp project_changed?(_scope, _task), do: false

  # With a task: every File row whose mtime (off the harness's manifest) moved
  # since the task started, narrowed by attribution — mtime cannot tell an agent's
  # write from a rebase. `cwd` is nil here by construction; the harness sends
  # edit paths project-relative, so `relativize/2` passes them through.
  #
  # No cleanup thunk: `changed_files_for_task/3` intersects the ledger with the
  # task window, and consuming rows would starve it for the rest of the task.
  defp remote_changed_files(scope, %{started_at: started_at} = task, opts)
       when not is_nil(started_at) do
    {changed_files_for_task(scope, task, opts), fn -> :ok end}
  end

  # Without a task: what this session wrote, as PostToolUse recorded it. Empty
  # means a quiet stop. The second element consumes the returned paths once they
  # have been used, so the next stop with nothing new sees an empty ledger
  # instead of this one's leftovers. See knowledge/analysis, "Changed files and attribution".
  defp remote_changed_files(scope, _task, opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) ->
        agent_id = Keyword.get(opts, :agent_id)
        paths = attributed_paths(session_id, agent_id)
        files = Files.get_by_paths(scope, paths)
        {files, fn -> consume_attributed_paths(session_id, agent_id, paths) end}

      _ ->
        {agent_changed_files(scope, opts), fn -> :ok end}
    end
  end

  defp consume_attributed_paths(session_id, nil, paths),
    do: FileEdits.consume_edits(session_id, paths)

  defp consume_attributed_paths(session_id, agent_id, paths) when is_binary(agent_id),
    do: FileEdits.consume_edits_by_agent(session_id, agent_id, paths)

  @doc false
  def remote_changed_files_for_test(scope, task, opts),
    do: remote_changed_files(scope, task, opts)

  # The same answer for an agent with no session: the files it touched, as
  # `FileEdits.track_agent_edit/2` records them.
  #
  # No cleanup thunk: `get_edited_files_for_agent/1` is never consumed, so a
  # continuous in-BEAM agent could accumulate a stale ledger the way sessions did.
  # Unmeasured.
  defp agent_changed_files(scope, opts) do
    case Keyword.get(opts, :agent_id) do
      agent_id when is_binary(agent_id) ->
        agent_id
        |> FileEdits.get_edited_files_for_agent()
        |> then(&Files.get_by_paths(scope, &1))

      _ ->
        []
    end
  end

  @doc """
  Public only so the property that matters can be asserted directly: mtime
  moves, git state does not, and the blocking set follows what the session
  recorded rather than the clock. Same reasoning as `blocking_key/1`.
  """
  def changed_files_for_task(scope, %{started_at: started_at} = task, opts) do
    scope
    |> Files.changed_since(started_at)
    |> filter_by_session_attribution(scope, nil, task, opts)
  end

  # When a session is in play, narrow the changed-file set to files this
  # session+agent actually wrote (via PostToolUse); otherwise a parallel
  # session's writes leak into this stop. No session → no filter.
  defp filter_by_session_attribution(files, scope, cwd, task, opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) ->
        # PostToolUse stores whatever Claude passed, typically absolute;
        # `Files.path` is project-relative.
        attributed =
          session_id
          |> attributed_paths(Keyword.get(opts, :agent_id))
          |> Enum.map(&relativize(&1, cwd))
          |> MapSet.new()

        narrow_to_attributed(scope, files, attributed, session_id, task_started_at(task))

      _ ->
        files
    end
  end

  defp task_started_at(%{started_at: %DateTime{} = started_at}), do: started_at
  defp task_started_at(_task), do: nil

  # How many mtime-dirty files with zero attribution stop looking like a turn
  # and start looking like a rebase. Deliberately generous: over it the set is
  # discarded, and discarding a real turn's work is the expensive mistake.
  @rebase_sized 25

  # A session that recorded no edits wrote nothing; fail closed to an empty set
  # rather than blocking on every mtime-dirty file. Under `@rebase_sized` the
  # dirty set is kept unless `git_rewrite_at` (stamped by PostToolUse on a Bash
  # command able to move HEAD) is at or after the task start.
  # See knowledge/analysis, "Changed files and attribution".
  defp narrow_to_attributed(scope, files, attributed, session_id, started_at) do
    case {MapSet.size(attributed), length(files)} do
      {0, dirty} when dirty > @rebase_sized ->
        Logger.warning(
          "[Validation] session #{session_id} recorded no edits, but #{dirty} file(s) " <>
            "look changed — more than a turn writes. Treating the turn as having " <>
            "written nothing rather than blocking on all of them; if the agent did " <>
            "edit files, PostToolUse attribution is not reaching this project's " <>
            "File paths."
        )

        []

      {0, _dirty} ->
        if git_rewrote_tree?(scope, session_id, started_at) do
          Logger.warning(
            "[Validation] session #{session_id} recorded no edits, and ran a git " <>
              "command that can move HEAD since this task started — treating the " <>
              "dirty file(s) as inherited history rather than this turn's work."
          )

          []
        else
          files
        end

      _ ->
        Enum.filter(files, &MapSet.member?(attributed, &1.path))
    end
  end

  defp git_rewrote_tree?(scope, session_id, started_at) do
    case Sessions.get_by_external_id(scope, session_id) do
      %{git_rewrite_at: %DateTime{} = rewrote_at} ->
        is_nil(started_at) or DateTime.compare(rewrote_at, started_at) != :lt

      _ ->
        false
    end
  end

  defp relativize(path, cwd) when is_binary(path) and is_binary(cwd) do
    cond do
      Path.type(path) == :relative -> path
      String.starts_with?(path, cwd <> "/") -> Path.relative_to(path, cwd)
      true -> Path.relative_to(path, cwd)
    end
  end

  defp relativize(path, _cwd), do: path

  @doc """
  Split blocking findings into this session's and everyone else's.

  The second list is always empty: task evaluation judges the whole copy, the
  same way promotion does, so every blocker blocks whoever stops. Kept with its
  old shape so the call site stays readable; "is this mine to fix" is answered
  by `split_by_story_enforcement/3` and `split_by_role/2` instead.
  """
  @spec split_unattributed([Problems.Problem.t()], MapSet.t(String.t()) | nil) ::
          {[Problems.Problem.t()], [Problems.Problem.t()]}
  def split_unattributed(blocking, _session_paths), do: {blocking, []}

  # Sources `split_by_role/2` holds back from roles that do not fix code.
  @attribution_exempt_sources ~w(spex)

  # The attribution-exempt sources block only the roles that fix code: a QA or
  # product agent is not handed red spex. `Menu` gives those roles no problems;
  # this is the gate reading the same rule. No role (a Claude Code session)
  # keeps them blocking.
  defp split_by_role(blocking, role) do
    if RoleProfile.holds_problems?(role),
      do: {blocking, []},
      else: Enum.split_with(blocking, &(&1.source not in @attribution_exempt_sources))
  end

  # This session's edits, normalized like `filter_by_session_attribution/5`.
  # `nil` means attribution cannot be trusted; an empty set means the session
  # genuinely wrote nothing. The renderer treats the two differently.
  @doc """
  Public so the cwd-less case can be asserted directly: the bug it guards was a
  `nil` that reads as "attribution unavailable", visible only in the value.
  """
  @spec session_paths_for_test(Scope.t(), keyword(), boolean()) :: MapSet.t() | nil
  def session_paths_for_test(scope, opts, project_changed? \\ false),
    do: session_paths(scope, opts, project_changed?)

  # No `when is_binary(cwd)`: a scope without one is normal on the light harness,
  # and the harness sends paths project-relative, which `relativize/2` passes
  # through. `verify_against_ledger/3` still requires the paths to join real
  # File rows. See knowledge/analysis, "Changed files and attribution".
  defp session_paths(%Scope{cwd: cwd} = scope, opts, project_changed?) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) ->
        recorded =
          session_id
          |> attributed_paths(Keyword.get(opts, :agent_id))
          |> Enum.map(&relativize(&1, cwd))

        case split_by_working_copy(recorded, cwd) do
          {[], [_ | _]} ->
            # Every recorded edit landed outside this working copy: a session
            # working in another repo owns nothing here, however much the project
            # moved meanwhile.
            MapSet.new()

          {inside, _outside} ->
            inside
            |> MapSet.new()
            |> verify_against_ledger(scope, session_id)
            |> corroborate_with_disk(project_changed?)
        end

      _ ->
        agent_paths(scope, opts, project_changed?)
    end
  end

  defp session_paths(_scope, _opts, _project_changed?), do: nil

  # What an agent with no session wrote, recorded by `FileEdits`. An empty set is
  # a real answer: an agent that edited nothing this session owns nothing.
  defp agent_paths(%Scope{cwd: cwd}, opts, project_changed?) do
    case Keyword.get(opts, :agent_id) do
      agent_id when is_binary(agent_id) ->
        agent_id
        |> FileEdits.get_edited_files_for_agent()
        |> Enum.map(&relativize(&1, cwd))
        |> then(fn recorded -> elem(split_by_working_copy(recorded, cwd), 0) end)
        |> MapSet.new()
        |> corroborate_with_disk(project_changed?)

      _ ->
        nil
    end
  end

  # Which recorded edits are edits to *this* working copy. After `relativize/2`,
  # "still absolute" means "not under this cwd". Without a cwd everything counts
  # as inside, so an unnormalized project path still reaches the ledger join.
  defp split_by_working_copy(paths, cwd) when is_binary(cwd),
    do: Enum.split_with(paths, &(Path.type(&1) == :relative))

  defp split_by_working_copy(paths, _cwd), do: {paths, []}

  # An empty ledger means "no edits were recorded", not "no edits were made":
  # Bash edits (heredoc, `sed -i`) record nothing. When disk says the project
  # changed, an empty set becomes `nil` (attribution unusable, nothing demoted) —
  # never a set of paths, which would credit this session with others' changes.
  # See knowledge/analysis, "Changed files and attribution".
  defp corroborate_with_disk(nil, _project_changed?), do: nil

  defp corroborate_with_disk(paths, true) do
    case MapSet.size(paths) do
      0 -> nil
      _ -> paths
    end
  end

  defp corroborate_with_disk(paths, _project_changed?), do: paths

  # Does the attribution actually correspond to this project's files? A nonzero
  # join is evidence the comparison works. `get_by_paths/2` rather than listing
  # the ledger: this runs on every stop.
  defp verify_against_ledger(paths, scope, session_id) do
    cond do
      # An empty ledger is a fact about the session, not a broken recording:
      # an agent that made no edits is blocked by nothing. QA sessions write
      # under gitignored `.code_my_spec/qa/` and record no project edits.
      MapSet.size(paths) == 0 ->
        paths

      Files.get_by_paths(scope, MapSet.to_list(paths)) != [] ->
        paths

      # Recorded paths that name no project file: a QA session's gitignored
      # writes, or a recording that mangled its paths. Only disk tells them
      # apart, so `corroborate_with_disk/2` decides. Info, not warning: the
      # common case is a QA session doing its job.
      true ->
        Logger.info(
          "[Validation] session #{session_id} recorded #{MapSet.size(paths)} edited " <>
            "path(s), none of which name a file in this project. No project file is " <>
            "attributable to it; whether that is untracked work or a normalization " <>
            "failure is decided against the files this task changed on disk. If the " <>
            "latter, check that PostToolUse paths normalize against #{inspect(scope.cwd)}."
        )

        MapSet.new()
    end
  end

  defp attributed_paths(session_id, nil), do: FileEdits.get_edited_files(session_id)

  defp attributed_paths(session_id, agent_id) when is_binary(agent_id),
    do: FileEdits.get_edited_files_by_agent(session_id, agent_id)

  # A stop never starts, ingests or waits on an analyzer
  # (`.code_my_spec/rules/analysis_is_explicit.md`): runs come from
  # `start_analysis`, ready_for_qa certification and promotion. Only the
  # in-process validators run here.
  @nothing_enqueued %{enqueued: [], memoized: []}

  defp run_pipeline(scope, task, changed_files, config, opts) do
    if changed_files != [] do
      log_changed_files(changed_files)

      in_process =
        task
        |> StaticAnalysis.resolve_analyzers(changed_files, config)
        |> Enum.reject(&Map.has_key?(@subprocess_analyzers, &1))

      StaticAnalysis.run_analyzers(scope, in_process, changed_files, config, opts)
    end

    @nothing_enqueued
  end

  defp resolve_changed_files(scope, %{started_at: started_at}, _sync_result)
       when not is_nil(started_at) do
    Files.changed_since(scope, started_at)
  end

  defp resolve_changed_files(scope, _task, sync_result) do
    case sync_result.changed_paths do
      [] -> []
      paths -> Files.get_by_paths(scope, paths)
    end
  end

  defp check_blocking_problems(scope, changed_files, project_changed?, config, opts) do
    sources = active_blocking_sources(config)

    # Problems are an eventually consistent projection: block on what is
    # recorded, and say which run recorded it.
    problems_by_source =
      scope
      |> Problems.list_project_problems(sources: sources)
      |> Enum.group_by(& &1.source)

    scope_context = %{
      changed_file_paths: Enum.map(changed_files, & &1.path),
      changed_component_ids:
        changed_files
        |> Enum.map(& &1.component_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq(),
      specs_ready_story_ids: Blocking.specs_ready_story_ids(scope),
      criterion_story_ids: Files.bdd_spec_story_id_by_path(scope),
      spec_file_story_ids: Files.bdd_spec_story_id_by_path(scope),
      story_ids_by_number: Stories.list_story_ids_by_number(scope)
    }

    # Each finding is labelled with the run that recorded it — its commit and its
    # age — and always blocks. Whether a run saw the current code is the promote
    # gate's question. Restricted to `Run.sources/0`: `qa_validation` is an
    # in-process validator with no ledger row.
    sources_with_problems = Map.keys(problems_by_source)
    ledger_sources = Enum.filter(sources_with_problems, &(&1 in Run.sources()))

    {blocking, advisory} = partition_problems(problems_by_source, config, scope_context)
    setting = advisory_findings(config)
    {blocking, never_blocks} = Enum.split_with(blocking, &can_block?(&1, setting))
    advisory = advisory ++ never_blocks
    session_paths = session_paths(scope, opts, project_changed?)
    {blocking, unattributed} = split_unattributed(blocking, session_paths)
    {blocking, not_this_role} = split_by_role(blocking, Keyword.get(opts, :agent_role))
    advisory = advisory ++ unattributed ++ not_this_role

    decide(blocking, advisory,
      # Computed here, from the opts that carry the identity; `decide/3` is
      # handed a freshly built list.
      internal_agent?: internal_agent?(opts),
      # The run each source's findings came from: commit, age and duration.
      answers: answers(scope, ledger_sources),
      # Why a source that has never answered could not run.
      run_failures: run_failures(scope, ledger_sources),
      # Whether the build that decided a source's findings was older than the
      # tree it decided about. Stamped on the run by the harness, because only
      # the harness can compare its own boot sha against its own checkout.
      analyzer_staleness: analyzer_staleness(scope, sources_with_problems),
      # A rerun that failed behind an older answer; those findings were not re-checked.
      failed_reruns: failed_reruns(scope, sources_with_problems),
      # How to see these findings without stopping again. Only credo has one:
      # its plain invocation hides the low-priority band, so `mix credo` can
      # answer "found no issues" on findings this gate reports. `mix test` and
      # `mix spex` reproduce themselves.
      reproduce_commands: %{
        "credo" => {CredoRun.reproduce_command(), CredoRun.reproduce_note()}
      },
      # Which files this session actually wrote; labels what blocks.
      session_paths: session_paths,
      # Whose story each spex finding belongs to. Orientation only: nothing
      # here demotes anything.
      story_assignment: story_assignments(scope, blocking ++ advisory, scope_context),
      # When and on what commit each blocking spex finding's specs_ready latch
      # was earned — a fact to check against HEAD before assuming you broke it.
      specs_ready_stamp: specs_ready_stamps_by_path(scope, blocking, scope_context)
    )
  end

  @doc """
  The run each source's findings came from, as `%{source => %{commit:,
  finished_at:, duration:}}`: the latest completed full run, however old.

  Read off `Analysis.latest_answer/2`, the same run whose problems are
  recorded, so the label and the findings describe one run. `commit` is nil
  where no harness reported one.
  """
  @spec answers(Scope.t(), [String.t()]) :: %{String.t() => map()}
  def answers(scope, sources) do
    for source <- sources,
        %Run{} = run <- [Analysis.latest_answer(scope, source)],
        into: %{},
        do:
          {source,
           %{
             commit: run.completed_commit,
             finished_at: run.finished_at,
             duration: duration(run)
           }}
  end

  @doc """
  Why a source that has never produced an answer could not run.

  Only for sources with no completed run at all. `Reconciler.fail/2` writes
  the analyzer's own words to `Run.output` (or the reason to `stats["error"]`);
  surfacing them tells the agent the precondition that failed (a pending
  migration, an un-onboarded copy) instead of leaving it to chase findings.

  Truncated because the stop response has a byte cap; the first lines are
  where these tools put the sentence that matters.
  """
  @spec run_failures(Scope.t(), [String.t()]) :: %{String.t() => String.t()}
  def run_failures(_scope, []), do: %{}

  def run_failures(scope, sources) do
    for source <- sources,
        is_nil(Analysis.latest_answer(scope, source)),
        run = RunsRepository.latest_full_run(scope, source),
        reason = failure_reason(run),
        into: %{},
        do: {source, reason}
  end

  defp failure_reason(%Run{status: :failed, output: output}) when is_binary(output) do
    case String.trim(output) do
      "" -> stats_error(nil)
      text -> summarize_failure(text)
    end
  end

  # A run that never produced output: `Reconciler.fail/2` writes the reason to
  # `stats["error"]`, while `output` is what the tool printed. Both columns are
  # read. See knowledge/analysis, "Stop response".
  defp failure_reason(%Run{status: :failed, stats: stats}), do: stats_error(stats)

  defp failure_reason(_run), do: nil

  defp stats_error(%{"error" => error}) when is_binary(error), do: summarize_failure(error)
  defp stats_error(_stats), do: nil

  defp summarize_failure(text) do
    text |> String.split("\n") |> Enum.take(6) |> Enum.join("\n") |> truncate(600)
  end

  defp truncate(text, cap) when byte_size(text) <= cap, do: text
  defp truncate(text, cap), do: binary_part(text, 0, cap) <> "…"

  @doc """
  Per source, the harness's note about its own build being behind the tree.

  Read off the run rather than recomputed, because the question is about the
  moment that result was produced. A fix to the analyzer is not in force until
  the harness is rebuilt, which from inside the stop loop looks like an
  ordinary stale finding.
  """
  @spec analyzer_staleness(Scope.t(), [String.t()]) :: %{String.t() => String.t()}
  def analyzer_staleness(_scope, []), do: %{}

  def analyzer_staleness(scope, sources) do
    for source <- sources,
        run = RunsRepository.latest_full_run(scope, source),
        note = get_in(run.stats || %{}, ["analyzer_staleness"]),
        is_binary(note),
        into: %{},
        do: {source, note}
  end

  @doc """
  Per source, the newest full run when it failed after the latest answer.

  The findings still come from that older answer (`Analysis.latest_answer/2`
  keeps it good), so the reader must be told the rerun failed and why.
  """
  @spec failed_reruns(Scope.t(), [String.t()]) :: %{String.t() => map()}
  def failed_reruns(_scope, []), do: %{}

  def failed_reruns(scope, sources) do
    for source <- sources,
        %Run{status: :failed} = run <- [RunsRepository.latest_full_run(scope, source)],
        %Run{} = answer <- [Analysis.latest_answer(scope, source)],
        DateTime.compare(run.started_at, answer.started_at) == :gt,
        into: %{},
        do:
          {source,
           %{
             failed_at: run.finished_at || run.started_at,
             reason: failure_reason(run),
             answered_at: answer.finished_at || answer.started_at
           }}
  end

  # Nil rather than zero when either end is missing: zero would read as an
  # instant run.
  defp duration(%{started_at: %DateTime{} = from, finished_at: %DateTime{} = to}),
    do: DateTime.diff(to, from, :second)

  defp duration(_), do: nil

  # Only `StopDecision` names an agent without naming a session.
  defp internal_agent?(opts) do
    is_binary(Keyword.get(opts, :agent_id)) and is_nil(Keyword.get(opts, :session_id))
  end

  defp active_blocking_sources(config) do
    configurable =
      for {source, {field, _scope_fn}} <- @configurable_sources,
          mode_for(config, field) != :off,
          do: source

    ["compiler" | configurable]
  end

  # Rows predating a new analyzer_mode column have NULL for that field since
  # schema `default:` only applies on struct build, not on DB load. Fall back
  # to the schema default so the blocking decision stays consistent.
  defp mode_for(config, field) do
    Map.get(config, field) || Map.fetch!(%ProjectConfiguration{}, field)
  end

  defp partition_problems(problems_by_source, config, scope_context) do
    {compiler_block, compiler_advisory} =
      partition_compiler(Map.get(problems_by_source, "compiler", []), config.compile_warnings)

    {configurable_block, configurable_advisory} =
      Enum.reduce(@configurable_sources, {[], []}, fn {source, {field, scope_fn}},
                                                      {block_acc, advisory_acc} ->
        mode = mode_for(config, field)
        problems = Map.get(problems_by_source, source, [])

        {enforced, unenforced} =
          Blocking.split_by_story_enforcement(source, problems, scope_context)

        {block, advisory} = apply_mode(enforced, mode, scope_fn, scope_context)
        {block_acc ++ block, advisory_acc ++ advisory ++ unenforced}
      end)

    {compiler_block ++ configurable_block, compiler_advisory ++ configurable_advisory}
  end

  defp partition_compiler(problems, :block), do: {problems, []}

  # Errors always block; only warnings are gated by compile_warnings.
  defp partition_compiler(problems, :dont_block) do
    Enum.split_with(problems, &(&1.severity == :error))
  end

  # The blocking predicate lives in the `Validation.Blocking` leaf so Promotion
  # and Analysis read it without depending on Validation.
  defdelegate can_block?(problem, advisory_findings), to: Blocking
  defdelegate advisory_findings(scope_or_config), to: Blocking
  defdelegate blockable(scope, problems), to: Blocking
  defdelegate enforceable(scope, problems), to: Blocking

  # `%{file_path => :mine | :unassigned | {:elsewhere, label}}` for spex
  # findings whose story can be identified. Spex only: no other source has a
  # story behind it. Paths that resolve to no story are absent rather than
  # `:unassigned` — "unclaimed story" and "not a story's spex" are different
  # facts. The label is the destination checkout's.
  defp story_assignments(scope, problems, ctx) do
    %{criterion_story_ids: by_path, story_ids_by_number: by_number} = ctx

    paths =
      for %{source: "spex", file_path: path} <- problems, is_binary(path), uniq: true, do: path

    case paths do
      [] ->
        %{}

      paths ->
        assigned = Stories.list_story_working_copy_ids(scope)
        mine = scope.active_working_copy_id
        labels = copy_labels(assigned)
        story_assignments_for(paths, assigned, mine, labels, by_path, by_number)
    end
  end

  # `%{file_path => %{at:, commit:}}` for blocking spex findings whose story
  # holds the specs_ready latch. Queries `Stories` only for the story ids
  # involved.
  defp specs_ready_stamps_by_path(scope, blocking, ctx) do
    %{
      criterion_story_ids: by_path,
      spec_file_story_ids: by_spec_file,
      story_ids_by_number: by_number,
      specs_ready_story_ids: ready_ids
    } = ctx

    pairs =
      for %{source: "spex", file_path: path} <- blocking,
          is_binary(path),
          story_id = Blocking.story_id_for(path, by_path, by_spec_file, by_number),
          not is_nil(story_id),
          MapSet.member?(ready_ids, story_id),
          uniq: true do
        {story_id, path}
      end

    case pairs do
      [] ->
        %{}

      pairs ->
        story_ids = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        stamps = Stories.specs_ready_stamps(scope, story_ids)
        Map.new(pairs, fn {story_id, path} -> {path, Map.get(stamps, story_id)} end)
    end
  end

  # A project nobody has assigned anything on gets no note at all: "unassigned"
  # would be true of every story and tell the reader nothing.
  defp story_assignments_for(_paths, assigned, _mine, _labels, _by_path, _by_number)
       when assigned == %{},
       do: %{}

  defp story_assignments_for(paths, assigned, mine, labels, by_path, by_number) do
    for path <- paths,
        story_id = Map.get(by_path, path) || Blocking.story_id_from_path(path, by_number),
        not is_nil(story_id),
        into: %{} do
      {path, assignment_for(story_id, assigned, mine, labels)}
    end
  end

  defp assignment_for(story_id, assigned, mine, labels) do
    case Map.get(assigned, story_id) do
      nil -> :unassigned
      ^mine -> :mine
      other -> {:elsewhere, Map.get(labels, other, other)}
    end
  end

  defp copy_labels(assigned) do
    assigned
    |> Map.values()
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn id, acc ->
      case WorkingCopies.fetch(id) do
        {:ok, copy} -> Map.put(acc, id, copy.label || copy.root || id)
        _ -> acc
      end
    end)
  end

  defp apply_mode(_problems, :off, _scope_fn, _ctx), do: {[], []}
  defp apply_mode(problems, :block_all, _scope_fn, _ctx), do: {problems, []}
  defp apply_mode(problems, :dont_block, _scope_fn, _ctx), do: {[], problems}

  defp apply_mode(problems, :block_changed, scope_fn, ctx) do
    Enum.split_with(problems, in_scope_fn(scope_fn, ctx))
  end

  defp in_scope_fn(:by_file_path, %{changed_file_paths: paths}) do
    &(&1.file_path in paths)
  end

  defp in_scope_fn(:by_component_id, %{changed_component_ids: ids}) do
    &(&1.component_id in ids)
  end

  defp decide([], [], _opts), do: {:ok, nil}

  # Nothing blocks, and something may still be worth saying: a working copy
  # surfaces every finding about it, regardless of assignment. Only the
  # assignment sentence, and only when there is one — a list of advisory
  # findings on every allowed stop is wallpaper.
  defp decide([], advisory, opts) do
    Logger.warning("[Validation] #{length(advisory)} advisory problem(s) not blocking")

    {:ok, Problems.advisory_assignment_note(advisory, Keyword.get(opts, :story_assignment, %{}))}
  end

  defp decide(blocking, advisory, opts) do
    reason =
      Problems.render_stop_response(
        blocking,
        advisory,
        # `:internal_agent?` tells the renderer this agent is not the one
        # waiting on a rerun (no "curl analysis/wait"), and its edits are its own.
        opts
      )

    {:error, reason, blocking_key(blocking)}
  end

  # What is blocking, comparable across stops. Not the rendered reason: that
  # carries relative ages and changes every stop, so repeat detection hashing it
  # would never build a streak. A fixed, new or moved finding changes this;
  # waiting does not.
  @doc """
  Public only so the property that matters can be asserted directly: stable
  while a source ages, different the moment a finding changes.
  """
  def blocking_key([]), do: nil

  def blocking_key(blocking) do
    blocking
    |> Enum.map(&{&1.source, &1.file_path, &1.line, &1.message})
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp log_changed_files(changed_files) do
    summary =
      changed_files
      |> Enum.group_by(& &1.role)
      |> Enum.map_join(", ", fn {role, files} -> "#{role}(#{length(files)})" end)

    Logger.info("[Validation] Changed files: #{summary}")
  end
end
