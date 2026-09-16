defmodule CodeMySpec.Validation do
  @moduledoc """
  Orchestrates stop hook validation: file sync, in-process validators, and
  the blocking decision — with subprocess analyzers (compile, credo, tests,
  spex) enqueued as background `Analysis` runs instead of executed inline.

  The stop decision is made immediately from persisted Problems; background
  runs reconcile new problems on their own schedule (surviving the hook's
  HTTP timeout) and apply to the next stop. `Analysis`'s run ledger skips
  any analyzer whose inputs haven't changed since its last completed run.

  The blocking decision consults `ProjectConfiguration` modes per source:

  - `:off` — source never blocks (matches `resolve_analyzers` filtering)
  - `:block_all` — every problem from this source blocks
  - `:block_changed` — only problems on files/components changed during the
    task block; others are advisory
  - `:dont_block` — problems are persisted but never block

  Spex is filtered per-story before the mode applies: a spex failure only
  counts toward blocking when the owning story's `specs_ready` latch is
  set. Failures on stories still mid-build are advisory regardless of
  mode, which is what makes enabling spex project-wide survivable.

  The blocking check runs even when no files changed this turn — outstanding
  problems from a prior run still apply.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.AcceptanceCriteria,
      CodeMySpec.AgentTasks,
      CodeMySpec.Agents,
      CodeMySpec.Analysis,
      CodeMySpec.BddSpecs,
      CodeMySpec.Configurations,
      CodeMySpec.Environments,
      CodeMySpec.FileEdits,
      CodeMySpec.Files,
      CodeMySpec.Notifications,
      CodeMySpec.Problems,
      CodeMySpec.Requirements,
      CodeMySpec.Sessions,
      CodeMySpec.StaticAnalysis,
      CodeMySpec.Stories,
      CodeMySpec.TaskOwner,
      CodeMySpec.Users,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  require Logger

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.BddSpecs.Parser
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
  alias CodeMySpec.WorkingCopies

  # Analyzer atoms that execute as mix subprocesses → their Analysis source.
  # Everything else in a resolved analyzer set runs in-process (fast) inside
  # this request.
  @subprocess_analyzers %{credo: "credo", exunit_stale: "exunit", spex_stale: "spex"}

  # Configurable source → {ProjectConfiguration field, scope predicate for
  # :block_changed mode}.
  @configurable_sources %{
    "credo" => {:credo, :by_file_path},
    "exunit" => {:exunit, :by_component_id},
    "spex" => {:spex, :by_file_path},
    "spec_validation" => {:spec_validation, :by_file_path},
    "qa_validation" => {:qa_validation, :by_file_path}
  }

  @doc """
  Run the full validation pipeline for a stop hook.

  Returns `{:ok, %{changed_files: [File.t()]}}` on success, or
  `{:error, reason}` if compilation fails or the blocking check rejects.

  ## Options

  - `:compile_output_file` - pre-recorded diagnostics JSONL (test-only)
  - `:credo_output_file` - pre-recorded credo JSON (test-only)
  - `:exunit_output_file` - pre-recorded ExUnit JSON (test-only)
  - `:spex_output_file` - pre-recorded spex JSONL (test-only)
  - `:session_id` - external session id; when present, the changed-file
    set is intersected with PostToolUse-attributed edits for this
    `(session_id, agent_id)`. Problems on files attributed elsewhere
    are excluded from the block decision.
  - `:agent_id` - sub-agent id; nil means the main agent. Combined with
    `:session_id` for the FileEdits attribution lookup.
  - `:await` - test-only; block until enqueued background runs finish before
    the blocking check, restoring synchronous semantics for deterministic
    specs. The stop hook never passes this.

  Set by `StopController` from the `test_output_files` request param so
  cassette-backed specs can drive the pipeline with known outputs without
  relying on `System.cmd` side effects.
  """
  # The pre-recorded output options, named once so the refusal below and the
  # doc above cannot drift apart.
  @test_output_file_opts [
    :compile_output_file,
    :credo_output_file,
    :exunit_output_file,
    :spex_output_file
  ]

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

  # No working copy on this machine. Until the light harness that is a project
  # nobody can look at, and this clause answered `{:ok, …}` — no analysis, no
  # blocking check, an unconditional allow. That was right while the only way to
  # reach it was a caller with no project on disk anywhere. It stopped being
  # right the moment a harness started holding the disk on the other end of a
  # channel, because the stop hook then arrived here on every single agent turn
  # and got an answer computed from nothing.
  #
  # So the question is no longer "is there a working copy here" but "is there
  # one anywhere I can reach". A harness holding this project is the yes.
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

  # `cwd` is not the same claim as "there is a working copy here". It is set for
  # any resolved scope, so the clause above matches on the
  # server too, where `scope.environment` is a `Harness` that walks nothing —
  # and the sync it ran deleted every row for the checkout it was named after.
  #
  # An environment that cannot scan is the case the `cwd: nil` clause already
  # answers: ask the harness that holds this project, and if none does, return
  # the empty result rather than one computed from a walk that never happened.
  defp local_validate_stop(%Scope{} = scope, task, opts, cwd, sync_result) do
    FileComponentSync.sync_from_files(scope,
      base_dir: cwd,
      changed_paths: sync_result.changed_paths,
      removed_module_names: sync_result.removed_module_names
    )

    # An agent with no session names its own changed set, exactly as it does on
    # the remote path. The scan's dirty list cannot stand in for it: by the time
    # a turn-end decision runs, the file the agent just wrote has usually been
    # synced already and is no longer dirty — which is how the internal path
    # came to see an empty set and had to guess around it.
    all_changed =
      case agent_changed_files(scope, opts) do
        [] -> resolve_changed_files(scope, task, sync_result)
        edited -> edited
      end

    changed_files = filter_by_session_attribution(all_changed, scope, cwd, task, opts)

    config = Configurations.get_or_create(scope)

    # Read *before* the pipeline enqueues, and that ordering is the whole of it.
    # Asked afterwards, this set contains the runs this very stop just started,
    # so every stale finding would be superseded on every stop and the gate
    # would only ever block on fresh ones — which a finding stops being the
    # moment anything is edited. What `23c8e006` describes is narrower: a rerun
    # that was *already* going when the stop arrived, whose result will replace
    # these findings without the agent doing anything.
    already_running = Analysis.in_flight(scope)

    analysis = run_pipeline(scope, task, changed_files, config, opts)

    if Keyword.get(opts, :await, false), do: Analysis.await_all(scope)

    opts = Keyword.put(opts, :already_running, already_running)

    with {:ok, note} <-
           check_blocking_problems(scope, changed_files, all_changed != [], config, opts) do
      {:ok, %{changed_files: changed_files, analysis: analysis, advisory_note: note}}
    end
  end

  # The same pipeline, minus the two steps that need a disk here.
  #
  # `FileSync.sync_changed/2` is skipped because the harness has already done
  # its equivalent: it scanned its own working copy and reconciled the whole
  # manifest over the channel, so the File rows this reads are current with the
  # disk by a different route. `StaticAnalysis.run_analyzers/5` — the in-process
  # validators — is skipped because those read file contents, which never cross
  # the wire.
  #
  # Everything that is left is database work and runs unchanged: the same
  # changed-file scoping, the same configuration modes, the same
  # `Analysis.ensure_stale_runs/3` (dispatched to the harness rather than to a
  # local queue), and the same blocking check. The point is that the *decision*
  # is identical; only where the tools ran differs.
  # Pre-recorded outputs cannot cross the channel, and saying so is the fix.
  #
  # `:compile_output_file` and friends name a file on *this* machine, and on
  # this path the analyzers run on the harness's. Ignoring them and carrying on
  # is what QA hit: a `test_output_files` post came back with the ordinary
  # "analysis running: compiler, credo, exunit, spex -- results apply next
  # stop", dispatched a real run against the sandbox checkout, and still showed
  # no spex problems ninety seconds and several re-posts later. The parameter
  # was read, accepted, and dropped, and every symptom pointed at a slow
  # analyzer instead.
  #
  # Refused rather than made to work. These fixtures exist so cassette-backed
  # specs can drive the pipeline without depending on `System.cmd` side effects;
  # shipping host-local paths to another machine is not a smaller version of
  # that, it is a different feature. Issue `5151df37`, story 895 -- where the
  # report's own guess was a `Mix.env()` gate, which is not what this is: the
  # param is extracted in every environment and honoured on the local path.
  defp remote_validate_stop(scope, task, opts) do
    case Keyword.take(opts, @test_output_file_opts) do
      [] -> do_remote_validate_stop(scope, task, opts)
      supplied -> {:error, fixtures_not_honored(supplied), nil}
    end
  end

  defp fixtures_not_honored(supplied) do
    names = supplied |> Keyword.keys() |> Enum.map_join(", ", &inspect/1)

    """
    `test_output_files` was supplied (#{names}) but this project's analyzers run \
    on a harness, not here -- so those paths name files on the wrong machine \
    and nothing would have read them.

    Nothing was run and nothing was recorded. Had this been ignored, the stop \
    would have dispatched a real analyzer run and answered "results apply next \
    stop", which is indistinguishable from a slow analyzer.

    Pre-recorded outputs are for specs driving the pipeline in-process, where \
    the fixture and the analyzer are on the same disk. To exercise the blocking \
    side against a harness-held copy, let the real analyzers run and assert on \
    what they find.\
    """
  end

  defp do_remote_validate_stop(scope, task, opts) do
    changed_files = remote_changed_files(scope, task, opts)
    config = Configurations.get_or_create(scope)
    project_changed? = project_changed?(scope, task)

    already_running = Analysis.in_flight(scope)

    analysis = run_pipeline(scope, task, changed_files, config, opts)

    if Keyword.get(opts, :await, false), do: Analysis.await_all(scope)

    opts = Keyword.put(opts, :already_running, already_running)

    with {:ok, note} <-
           check_blocking_problems(scope, changed_files, project_changed?, config, opts) do
      {:ok, %{changed_files: changed_files, analysis: analysis, advisory_note: note}}
    end
  end

  # Did anything in the project move while this task ran, before attribution has
  # a say. `changed_files` cannot answer it: both paths narrow that set to the
  # files this session is credited with, so asking it whether the session edited
  # is circular — it says no exactly when attribution is broken, which is the
  # one case that must not be believed.
  #
  # Without a task there is no window to ask about and no scan on this side, so
  # the honest answer is "no independent evidence" and the ledger stands alone.
  defp project_changed?(scope, %{started_at: started_at}) when not is_nil(started_at),
    do: Files.changed_since(scope, started_at) != []

  defp project_changed?(_scope, _task), do: false

  # With a task, the same answer the local path gives: every File row whose
  # mtime moved since the task started. mtime comes off the harness's manifest,
  # so this needs no disk.
  #
  # Narrowed by attribution for the same reason the local path is, and it was
  # not: mtime cannot tell "the agent wrote this" from "git wrote this", and a
  # rebase rewrites mtimes on everything it touches. The window is
  # `started_at`, so the longer a task stays open the more of the repo it
  # swallows — a task blocked upstream for days collects the lot.
  #
  # `cwd` is nil here by construction: this path exists precisely because the
  # disk is on the other end of a channel. The harness sends its edit paths
  # project-relative, so `relativize/2` has nothing to strip and passes them
  # through.
  defp remote_changed_files(scope, %{started_at: started_at} = task, opts)
       when not is_nil(started_at) do
    changed_files_for_task(scope, task, opts)
  end

  # Without a task, the local path uses the paths its own scan found dirty.
  # There is no scan here, so the equivalent is what this session actually
  # wrote — PostToolUse records every Write/Edit, and the harness sends those
  # paths project-relative precisely so they resolve to File rows here.
  #
  # Empty means the agent wrote nothing this session, which is a quiet stop and
  # is treated as one. It does not mean "could not tell": a session that edited
  # something has those edits recorded, and a project with no harness never
  # reaches this function at all.
  defp remote_changed_files(scope, _task, opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) ->
        session_id
        |> attributed_paths(Keyword.get(opts, :agent_id))
        |> then(&Files.get_by_paths(scope, &1))

      _ ->
        agent_changed_files(scope, opts)
    end
  end

  # The same answer, for an agent that has no session to record against.
  #
  # This clause used to be `[]`, and that empty list is the whole of why the
  # internal path has been wrong twice. An empty changed set makes every
  # `block_changed` source advisory, so an agent was never told about the file
  # it had just broken; widening it to "owns the whole tree" then told a product
  # agent about 160 findings it had never seen. Both were guesses standing in
  # for a fact nobody was recording.
  #
  # `FileEdits.track_agent_edit/2` records it now, on every `write` and `edit`
  # the agent makes, so this path answers exactly what the session path answers:
  # the files this agent touched, resolved to their rows.
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
  # session+agent actually wrote (via PostToolUse). The mtime-based
  # `Files.changed_since` view picks up every dirty file on disk; without
  # this filter a parallel session's writes leak into the current stop's
  # block decision. No session → no filter (preserves behaviour for direct
  # callers that don't run inside the hook lifecycle).
  defp filter_by_session_attribution(files, scope, cwd, task, opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) ->
        # PostToolUse stores whatever Claude passed — typically absolute
        # paths like `/Users/.../project/lib/foo.ex`. Files.path is
        # project-relative (`lib/foo.ex`). Normalize attributed paths to
        # relative against cwd before comparison or every session with a
        # tracked edit would land empty.
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

  # How many mtime-dirty files stop looking like a turn and start looking like
  # a rebase.
  #
  # A number rather than a rule, because the two cases are only distinguishable
  # by size from here: a session writing through something other than
  # Write/Edit — a spex, a direct evaluator, the harness — records no
  # attribution and is indistinguishable from a session whose attribution
  # broke. What separates them in practice is scale. The reported incident had
  # 232 dirty files against 6 real edits; a spex writes one or two.
  #
  # Deliberately generous. Over this line the set is discarded, and discarding
  # a real turn's work is the expensive mistake — an agent's own violations
  # would go unblocked. Under it, whether the mtime set is kept now also
  # depends on `git_rewrite_at` — see below. Before that field existed, size
  # was the only signal, and this was wrong for a small rebase with no
  # attribution: f8af8bf2.
  @rebase_sized 25

  # A session that recorded no edits wrote nothing, and the honest changed-file
  # set for that is empty.
  #
  # This returned `files` — every mtime-dirty file — on the reasoning that a
  # direct evaluator bypassing Write/Edit should not have its problems
  # suppressed. The cost of that reading is what it does when attribution goes
  # empty for a reason that is not "nothing was written": a session restart, or
  # a recorded path shape that does not match `Files.path`. Then the one filter
  # that narrows the set instead removes itself, and a stop blocks on every
  # dirty file in the tree.
  #
  # That happened. `git rebase` rewrites mtimes on everything it touches, so a
  # session that rebased onto a busy main inherited 232 mtime-dirty files, and
  # the hook blocked five times running on 49 credo violations in spex belonging
  # to three other stories. The only compliant response was to edit code the
  # agent did not own, which is a gate that cannot be satisfied honestly.
  #
  # Failing closed inverts the risk into the recoverable direction: a missed
  # violation is caught by the next analysis run and stays on the Problems page,
  # while a repo-wide block teaches everyone to route around the gate. Loudly,
  # because "the agent wrote nothing" and "attribution is broken" are different
  # and only the log can tell them apart.
  #
  # Size alone cannot tell a small rebase from a turn written outside
  # Write/Edit — both are a handful of dirty files with zero attribution
  # (f8af8bf2: one commit, already pushed by a different session sharing this
  # working copy, landed by a routine fetch+rebase and got credited to
  # whoever stopped next). `git_rewrite_at` is the signal size never could
  # be: `PostToolUse` stamps it on this session the moment it runs a Bash
  # command able to move `HEAD` without Write/Edit. A rewrite recorded at or
  # after the task started means these dirty files may be inherited history,
  # so the under-threshold set is trusted only when no such command ran.
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

  A finding in a file this session never edited does not block. Several agents
  share this repo and rebase onto main, so a warning one pushes became a hard
  block on every other's stop — and the obvious repair on someone else's
  in-flight file can be actively wrong, which leaves editing code you do not
  own or staying blocked as the only two responses.

  Three things refuse to demote. Two because the failure mode points the same
  way — a gate that quietly stops blocking is worse than one that blocks too
  much, and it is invisible:

    * A `nil` attribution set, which means attribution is *unusable* — no
      session id, or recorded paths that join no File row in this project.
      Nothing can be concluded from a set that means nothing.
    * A finding with no `file_path`. A spex that died in `setup_all` has
      nothing to attribute; unattributable is not the same as somebody else's,
      and collapsing them drops the finding nobody can place.

  An **empty** set is not one of them, and used to be. It was refused on the
  reasoning that "the session wrote nothing" and "attribution broke" are
  indistinguishable — true when it was written, and no longer the whole
  picture: `verify_against_ledger/3` now answers `nil` for the broken case
  specifically, so the two arrive here as different values. What is left when a
  session records zero edits is a session that edited nothing, and a session
  that edited nothing cannot own a finding in a file.

  That case was the expensive one. A QA agent writes no project files at all,
  so it hit this on every stop and every finding blocked — `76008385` is one
  following the advice exactly (`git log -1` on each path, confirmed neither
  was its own, escalated to the owner rather than editing an in-flight file)
  and being told the same thing again on the next stop, with no action
  available that would change the answer.

  No special case implements this. `MapSet.member?/2` on an empty set is false
  for everything, so the ordinary branch already demotes each finding that is
  attributable at all — the empty-set clause had to be *removed* for the rule
  to apply, not added.

  The third refusal is **spex**, and it is the only source with a mandate test
  of its own. `split_by_story_enforcement/3` has already asked the question this
  demotion approximates — is this red the agent's to fix — and answered it from
  the owning story's `specs_ready` latch rather than from which files happened
  to be written this turn. A spex that reaches here is red on a story that was
  green once, which is a regression in this working copy, not somebody else's
  in-flight work.

  Stacking attribution on top of that turned `spex: :block_all` into a setting
  with no effect. Measured across one evening on this project: every agent,
  every stop, `demoted N blocking finding(s) to advisory`, N never zero, while
  the mode had read `:block_all` for months.

  Every other source keeps demoting. They have no per-story latch, so
  attribution is the only thing standing between an agent and a rebase's worth
  of findings it has no mandate to fix.

  Public so the property that decides whether the gate still works can be
  asserted directly, the same reason `blocking_key/1` is.
  """
  # Sources whose mandate is decided before this point, so attribution must not
  # decide it again.
  @attribution_exempt_sources ~w(spex)

  @spec split_unattributed([Problems.Problem.t()], MapSet.t(String.t()) | nil) ::
          {[Problems.Problem.t()], [Problems.Problem.t()]}
  # Story 894: an agent that made no edits is blocked by nothing — and nothing
  # means nothing, `@attribution_exempt_sources` included.
  #
  # The exempt list exists so a finding with no file to attribute, or a spex
  # failure that belongs to a story rather than a file, is not silently demoted
  # away from an agent that *was* working. Applied to a session that wrote
  # nothing at all it does the opposite: it hands that agent every failing spex
  # in the project. Measured 2026-08-20 — a QA session with a provably empty
  # `git status` was refused a stop over 26 spex failures in three unrelated
  # stories, all last touched days earlier by someone else (a9e9caca).
  #
  # Ownership is the whole question this function asks, and a session that
  # edited nothing owns nothing. There is no finding it could have caused.
  def split_unattributed(blocking, %MapSet{} = session_paths) do
    case MapSet.size(session_paths) do
      0 -> {[], blocking}
      _ -> Enum.split_with(blocking, &attributable_to?(&1, session_paths))
    end
  end

  def split_unattributed(blocking, _session_paths), do: {blocking, []}

  defp attributable_to?(problem, session_paths) do
    problem.source in @attribution_exempt_sources or
      not is_binary(problem.file_path) or
      MapSet.member?(session_paths, problem.file_path)
  end

  @doc """
  Split blocking findings whose source is stale *and* currently re-running.

  A finding in this state describes a tree that no longer exists, and a
  replacement is already on its way. Blocking on it produced a response whose
  two instructions could not both be satisfied — "fix these problems before
  stopping", and, four lines down, "do not re-fix anything you have already
  corrected; a rerun is in flight, stop again and let it replace these".

  `23c8e006` reports both halves of that. First with a rerun that was failing
  (2m32s then 2m53s against a typical 1m7s, under a concurrent provisioning
  drill), and then again — the case that settles the design — with a rerun that
  was perfectly healthy at "15s of a typical 19s". The second one had no failure
  to surface: the findings were already fixed on disk, the analyzer agreed
  (`422 findings project-wide, zero in that file`, instrument checked against
  the same rules still firing elsewhere), and the block was purely the lag
  between an edit and the sweep that measures it. Its line numbers had moved
  too, so following them lands on unrelated code.

  Both conditions are required. A stale source with nothing running still
  blocks — that is a real outstanding finding nobody is measuring, and waiting
  cannot help. A fresh source obviously blocks. Only the overlap is demoted,
  and only until the run lands: if the finding is real, the next stop blocks on
  the new result.

  **`in_flight` must be read before the stop's own pipeline enqueues anything.**
  Asked afterwards it contains the runs this very stop just started, so every
  stale finding is superseded on every stop and the gate only ever blocks on
  fresh ones — which a finding stops being the moment anything is edited. That
  is not a subtle degradation; it switches the gate off. Caught by
  `HarnessProjectChannelTest`'s "a sub-agent stopping with problems blocks,
  rather than killing the channel", which went green-to-red on the first
  version of this and is the reason the caller captures `already_running`
  before `run_pipeline/5`.

  This aligns the blocking path with the pending one, which already reached the
  same answer from the other side. `Hooks.Stop` treats in-flight analysis as a
  distinct outcome and, outside continuous mode, allows the stop with "results
  apply next stop" — but only when validation *passed*, because blocking
  findings return before that check. So a stop with no findings waited politely
  while a stop with stale ones was refused on data of the same age.

  Not to be confused with `cc1016a8`, which was the case where the rerun never
  comes at all. That is fixed separately (a sweep no longer drops a request for
  a busy source); if it recurs, this demotion would hide it, which is why the
  response still names the source as stale and says what is running.
  """
  @spec split_superseded([Problems.Problem.t()], [String.t()], [String.t()]) ::
          {[Problems.Problem.t()], [Problems.Problem.t()]}
  def split_superseded(blocking, stale_sources, in_flight) do
    replacing = MapSet.intersection(MapSet.new(stale_sources), MapSet.new(in_flight))

    Enum.split_with(blocking, &(not MapSet.member?(replacing, &1.source)))
  end

  # Same reasoning as `log_demotions/2`: the gate declining to block is the
  # interesting case, and it is invisible in the response.
  defp log_supersessions([], _opts), do: :ok

  defp log_supersessions(superseded, opts) do
    sources = superseded |> Enum.map(& &1.source) |> Enum.uniq() |> Enum.join(", ")

    Logger.info(
      "[Validation] session #{inspect(Keyword.get(opts, :session_id))} — demoted " <>
        "#{length(superseded)} finding(s) to advisory: #{sources} is stale and re-running, " <>
        "so these describe a tree that no longer exists"
    )
  end

  # Loudly, because this is the gate declining to block. A demotion that is
  # right is uninteresting and a demotion that is wrong is invisible in the
  # response — the log is the only place the difference shows up.
  #
  # The empty-set case says so separately, because it is the one that can hide a
  # broken recorder. "Findings in files it never edited" is a comparison; "this
  # session recorded no edits at all" is the absence of one, and a PostToolUse
  # hook that stopped recording produces exactly that shape while looking like
  # an ordinary read-only session. Nothing here can tell them apart — the
  # demotion is correct for the ordinary one and wrong for the broken one — so
  # the log names the condition and lets a reader who sees it on a session that
  # was plainly writing files draw the conclusion.
  defp log_demotions([], _session_paths, _opts), do: :ok

  defp log_demotions(unattributed, %MapSet{} = session_paths, opts) do
    if MapSet.size(session_paths) == 0 do
      Logger.info(
        "[Validation] session #{inspect(Keyword.get(opts, :session_id))} — demoted all " <>
          "#{length(unattributed)} blocking finding(s) to advisory: this session recorded " <>
          "no edits at all, so it can own none of them. If it did write files, the " <>
          "PostToolUse recorder is not working and the gate is off for this session."
      )
    else
      log_edited_elsewhere(unattributed, opts)
    end
  end

  defp log_demotions(unattributed, _session_paths, opts),
    do: log_edited_elsewhere(unattributed, opts)

  defp log_edited_elsewhere(unattributed, opts) do
    paths = unattributed |> Enum.map(& &1.file_path) |> Enum.uniq() |> Enum.take(5)

    Logger.info(
      "[Validation] session #{inspect(Keyword.get(opts, :session_id))} — demoted " <>
        "#{length(unattributed)} blocking finding(s) to advisory: files it never " <>
        "edited (#{Enum.join(paths, ", ")})"
    )
  end

  # This session's edits, normalized the same way `filter_by_session_attribution`
  # normalizes them — PostToolUse stores whatever Claude passed, typically
  # absolute, while `Problem.file_path` is project-relative.
  #
  # `nil` rather than an empty set when there is no session or no cwd. Both mean
  # the comparison cannot be trusted: without a cwd the relativize is a no-op
  # and nothing would ever match, which would mark every finding as somebody
  # else's. An empty set from a session that genuinely wrote nothing is
  # different, and the renderer treats it as "no evidence" rather than "all
  # foreign" for the same reason.
  @doc """
  Public so the cwd-less case can be asserted directly, the same reason
  `HookDecision.channel_age_note/1` and `HealthController.degraded?/1` are.
  The bug this guards against was a `nil` that reads as "attribution
  unavailable", and the only way to catch that regressing is to look at the
  value rather than at the sentence built from it.
  """
  @spec session_paths_for_test(Scope.t(), keyword(), boolean()) :: MapSet.t() | nil
  def session_paths_for_test(scope, opts, project_changed? \\ false),
    do: session_paths(scope, opts, project_changed?)

  # No `when is_binary(cwd)`. A scope without one is the *normal* shape on the
  # light harness — the server holds no working copy — and requiring it threw
  # away attribution the session had.
  #
  # Measured on this session: 595 recorded edits, 363 of them already
  # project-relative, 269 joining File rows for this harness. Every one of those
  # was discarded, and every finding blocked, under the message "Attribution is
  # unavailable for this session" — which is a statement about `cwd` wearing the
  # costume of a statement about the session's work (9a623a13).
  #
  # Safe because the cwd was only ever needed to relativize *absolute* paths,
  # and `relativize/2` already returns the path unchanged when there is no cwd
  # to relativize against — as it does for a path that is relative already,
  # which is the shape the harness sends.
  #
  # And because the check that actually protects this is downstream:
  # `verify_against_ledger/3` still requires the recorded paths to join real
  # File rows, and still answers `nil` on zero. A set that means nothing cannot
  # demote anything whether or not a cwd was present, so dropping the guard
  # cannot manufacture a bogus demotion — it can only stop discarding a good
  # one.
  defp session_paths(%Scope{cwd: cwd} = scope, opts, project_changed?) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) ->
        recorded =
          session_id
          |> attributed_paths(Keyword.get(opts, :agent_id))
          |> Enum.map(&relativize(&1, cwd))

        case split_by_working_copy(recorded, cwd) do
          {[], [_ | _]} ->
            # Every edit this session recorded landed outside this working copy.
            # That is a session working in another repo, not a session whose
            # recording failed, and it owns nothing here however much the
            # project moved meanwhile.
            #
            # 042e343b is the shape: a task scoped to the `cms_new` and
            # `devops_drill` repos, finished and reported, refused a stop over
            # 26 spex last touched days earlier — while a *concurrent* agent's
            # uncommitted edit to `lib/code_my_spec/compile.ex` sat in the same
            # shared worktree, which is what kept answering "the project
            # changed". It had also been refused `git commit`, so it could not
            # have acted on the findings even had they been its own.
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

  # What an agent with no session wrote.
  #
  # `session_paths/3` answers `nil` for a caller with no session, and `nil`
  # means "attribution is unknown, do not demote anything" — which for an agent
  # under Alloy meant it owned every finding on the tree. That was the only
  # answer available while nothing recorded its edits. `FileEdits` records them
  # now, on every `write` and `edit` it makes, so the honest answer is the same
  # one an external session gets: these files, and no others.
  #
  # An empty set is a real answer here and not a missing one. An agent that has
  # edited nothing this session owns nothing — and it is `split_unattributed/2`
  # that turns that into "demoted to advisory", which is right: findings it did
  # not make are still real and still somebody's.
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

  # Which recorded edits are edits to *this* working copy.
  #
  # `relativize/2` leaves a path it cannot make relative absolute, so after it
  # runs, "still absolute" means "not under this cwd" — a different repo, a
  # scratchpad, another worktree.
  #
  # Only asked when there is a cwd to ask about. Without one, `relativize/2` is
  # a no-op and an absolute path is exactly the ambiguity 9a623a13 is about: it
  # could be a project file the recording failed to normalize. Everything counts
  # as inside there, so that case keeps falling through to the ledger join and
  # the corroboration, unchanged.
  defp split_by_working_copy(paths, cwd) when is_binary(cwd),
    do: Enum.split_with(paths, &(Path.type(&1) == :relative))

  defp split_by_working_copy(paths, _cwd), do: {paths, []}

  # An empty hook ledger means "no edits were recorded", which is not the same
  # fact as "no edits were made", and story 894's rule turns on the second one.
  #
  # `PostToolUse` records a path from `tool_input.file_path`. A `Bash` call
  # carries no such field, so an agent editing through a heredoc, `sed -i`, or
  # a script it writes and runs records nothing at all while its work sits
  # plainly on disk. Left alone, the rule would hand that agent a blanket
  # exemption from every finding in the project — the precise failure the rule
  # was written to end, pointed the other way.
  #
  # Disk is what separates the agent that made no edits from the one whose
  # edits the ledger could not see — `project_changed?/2`, read before
  # attribution narrows anything, because the narrowed set answers "no" exactly
  # when attribution is broken.
  #
  # It answers only whether the session edited, never what it edited: `nil` —
  # the value that already means "attribution is unusable, so nothing is
  # demoted" — and never a set of paths. Widening attribution from disk would
  # credit this session with whatever else changed in the working copy during
  # its task, which is what attribution exists to prevent.
  #
  # It carries a second case that used to be decided upstream and could not be:
  # a ledger whose paths name no file in this project. That is a QA session
  # writing under gitignored `.code_my_spec/qa/` (owns no project file, demote)
  # or a recording that mangled its paths (the project files behind them did
  # change, so they are here, and it blocks). One question separates them, and
  # it is this one — see the `true ->` branch of `verify_against_ledger/3`.
  defp corroborate_with_disk(nil, _project_changed?), do: nil

  defp corroborate_with_disk(paths, true) do
    case MapSet.size(paths) do
      0 -> nil
      _ -> paths
    end
  end

  defp corroborate_with_disk(paths, _project_changed?), do: paths

  # Does the attribution actually correspond to this project's files?
  #
  # The demotion turns on comparing recorded paths to `Problem.file_path`, and
  # a set that matches nothing looks exactly like a set that matches nothing
  # *because the session touched none of it* — one of which is a broken
  # recording and the other is a fact. Measured on this project: a healthy
  # session's 368 recorded paths join 988 File rows, and both shapes reach here
  # (the harness sends repo paths project-relative; only paths outside the
  # working copy, like a scratchpad, stay absolute). So a nonzero join is
  # evidence the comparison works, and zero is evidence of nothing.
  #
  # `nil` on zero, which disables demotion and blocks on everything — the same
  # direction every other guard here fails, because a gate that quietly stops
  # blocking is invisible and one that blocks too much is not.
  #
  # `get_by_paths/2` rather than listing the ledger: this runs on every stop,
  # and the full list is 4,544 rows here against an indexed lookup of the
  # session's own.
  defp verify_against_ledger(paths, scope, session_id) do
    cond do
      # An empty ledger is a fact about the session, not a broken recording, and
      # `f89429e4` is the commit that says so — "A session that edited nothing
      # does not block on anyone's findings". Story 894's rule states it
      # outright: an agent that made no edits is blocked by nothing.
      #
      # This answered `nil` for a few hours on 2026-08-20 because I read the
      # branch as an unexplained carve-out. It is not: `nil` means attribution
      # is *unusable*, which is a different claim from "this session touched
      # nothing", and conflating them blocks every zero-edit session on the
      # whole project's findings. QA sessions hit that constantly — their
      # artifacts live under `.code_my_spec/qa/`, which git ignores, so a
      # session doing real work records no edits by design.
      MapSet.size(paths) == 0 ->
        paths

      Files.get_by_paths(scope, MapSet.to_list(paths)) != [] ->
        paths

      # Recorded paths that name no file in this project used to answer `nil`
      # here, on the reasoning that "a broken recording looks identical to a
      # session that touched none of the project". The two are only identical
      # from inside this function; disk tells them apart, so the decision moves
      # to `corroborate_with_disk/2` and this answers what it actually knows —
      # no *project* file is attributable to this session.
      #
      # Both cases are real and they want opposite answers:
      #
      #   * a QA session whose only writes went to `.code_my_spec/qa/`, which
      #     git ignores and `Files` therefore never rows. Real work, no project
      #     file, owns none of the project's red (a9e9caca).
      #   * a recording that mangles its paths — the 595 absolute paths of
      #     9a623a13. The project files behind them did change, so they are in
      #     `changed_files`, and disk answers `nil` for exactly that reason.
      #
      # Logged at info: on the common path this is a QA session doing its job,
      # and a warning that fires every time one stops is noise that trains
      # people past the case where it means something.
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

  # In-process validators run synchronously (they're milliseconds); the four
  # subprocess sources go through Analysis — enqueued in the background,
  # memoized against the run ledger when inputs haven't changed. Returns the
  # `%{enqueued: [...], memoized: [...]}` summary.
  #
  # No changed files → stay quiet (criterion 5097): only re-enqueue sources
  # whose latest run failed (crash/timeout/superseded recovery), via
  # `only_failed`.
  defp run_pipeline(scope, task, [], config, opts) do
    excluded = StaticAnalysis.task_excluded_analyzers(task)
    declared = StaticAnalysis.task_analyzers(task)

    # Config gates a source here the same way `resolve_analyzers/3` gates
    # role-derived inclusion — but a source the active task declared via
    # `analyzers/0` bypasses it, same reasoning as there: `FixBddSpecs`
    # naming `spex_stale` has to survive `spex: :off` on a quiet stop too,
    # or the re-enqueue this branch exists for stops happening for the one
    # task that needed it.
    enabled =
      for {analyzer, source} <- @subprocess_analyzers,
          analyzer not in excluded,
          analyzer in declared or mode_for(config, config_field(analyzer)) != :off,
          do: source

    Analysis.ensure_stale_runs(
      scope,
      Enum.uniq(["compiler" | enabled]),
      Keyword.put(opts, :only_failed, true)
    )
  end

  defp run_pipeline(scope, task, changed_files, config, opts) do
    log_changed_files(changed_files)

    analyzers = StaticAnalysis.resolve_analyzers(task, changed_files, config)

    {subprocess, in_process} =
      Enum.split_with(analyzers, &Map.has_key?(@subprocess_analyzers, &1))

    StaticAnalysis.run_analyzers(scope, in_process, changed_files, config, opts)

    requests =
      ["compiler" | Enum.map(subprocess, &request_for(&1, changed_files, config))]
      |> Enum.uniq()

    Analysis.ensure_stale_runs(scope, requests, opts)
  end

  # Every source, credo included, scans the whole project. The config mode
  # decides whether credo *blocks*; it no longer decides what credo looks at.
  #
  # `:block_changed` still blocks only on violations in the turn's changed
  # files — that filtering lives in `apply_mode/4` at decision time. What
  # changes is that violations elsewhere are now persisted as advisory and
  # visible on the Problems page instead of never being looked for.
  defp request_for(analyzer, _changed_files, _config),
    do: Map.fetch!(@subprocess_analyzers, analyzer)

  defp config_field(:credo), do: :credo
  defp config_field(:exunit_stale), do: :exunit
  defp config_field(:spex_stale), do: :spex

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
    # recorded, report staleness, let the run this kicks off replace it.
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
      specs_ready_story_ids: specs_ready_story_ids(scope),
      criterion_story_ids: AcceptanceCriteria.spec_path_story_ids(scope),
      spec_file_story_ids: Files.bdd_spec_story_id_by_path(scope),
      story_ids_by_number: Stories.list_story_ids_by_number(scope)
    }

    # One pass over the file ledger for every source, rather than one per
    # source. See `Analysis.fresh_sources/2` — the answer is identical.
    #
    # Restricted to `Run.sources/0` first. "Stale" means a completed ledger
    # run whose fingerprint no longer matches the tree — a condition
    # `ensure_stale_runs/3` can act on by enqueuing a fresh one.
    # `spec_validation` and `qa_validation` are not in that ledger:
    # `Run.changeset/2` rejects any source outside `@sources`, so a row for
    # either can never exist, and `fresh_sources/2`'s lookup always misses.
    # They are in-process document validators instead
    # (`StaticAnalysis.Pipeline.run_validator/3`) — synchronous, and re-run
    # in this same request whenever their governing file is among this
    # turn's changed files, so their persisted Problems are exactly as
    # current as that file. Feeding them through the ledger check reported
    # them "stale" on every stop, forever, with a rerun `ensure_stale_runs/3`
    # never actually requests for either source (it only ever asks for
    # `compiler`, `credo`, `exunit`, `spex`) — a wait that could not end.
    sources_with_problems = Map.keys(problems_by_source)
    ledger_sources = Enum.filter(sources_with_problems, &(&1 in Run.sources()))
    fresh = Analysis.fresh_sources(scope, ledger_sources)
    stale_sources = Enum.reject(ledger_sources, &MapSet.member?(fresh, &1))

    {blocking, advisory} = partition_problems(problems_by_source, config, scope_context)
    session_paths = session_paths(scope, opts, project_changed?)
    {blocking, unattributed} = split_unattributed(blocking, session_paths)
    advisory = advisory ++ unattributed
    log_demotions(unattributed, session_paths, opts)

    {blocking, superseded} =
      split_superseded(blocking, stale_sources, Keyword.get(opts, :already_running, []))

    advisory = advisory ++ superseded
    log_supersessions(superseded, opts)

    {last_ran, run_duration, overtaken} = run_timing(scope, stale_sources)

    decide(blocking, advisory, stale_sources,
      # Computed here, from the opts that actually carry the identity.
      #
      # `decide/4` is handed this freshly built list rather than the caller's,
      # so asking it about `agent_id` inside `decide/4` answers nil for every
      # caller — the flag was always false and both renderings it governs were
      # dead on arrival. They passed their unit test because that test hands the
      # option straight to the renderer, which is exactly the instrument error
      # of checking a probe only where it cannot fail.
      internal_agent?: internal_agent?(opts),
      last_ran: last_ran,
      # Why a source that has never answered could not run. The analyzer's own
      # words are in `Run.output` and nothing read them back — `6f89b278` is
      # three days of blocked stops with the fix sitting in that column.
      run_failures: run_failures(scope, stale_sources),
      # Whether the build that decided a source's findings was older than the
      # tree it decided about. Stamped on the run by the harness, because only
      # the harness can compare its own boot sha against its own checkout.
      analyzer_staleness: analyzer_staleness(scope, sources_with_problems),
      # How long the run itself took. Read together with the age, this separates
      # "your edit predates this result" from "your edit landed while it was
      # running" — and only the first is fixed by waiting.
      run_duration: run_duration,
      # Read off the two fingerprints rather than inferred from the duration.
      overtaken: overtaken,
      # How to see these findings without stopping again. Only credo has one:
      # its plain invocation hides the low-priority band that `block_changed`
      # promotes, so `mix credo` answers "found no issues" on the very findings
      # that block. `mix test` and `mix spex` reproduce themselves.
      reproduce_commands: %{
        "credo" => {CredoRun.reproduce_command(), CredoRun.reproduce_note()}
      },
      # Which files this session actually wrote. Blocking findings outside that
      # set have already been demoted above, so this only labels what survives
      # — it is the safety net for the case where the set is unknown and
      # nothing was demoted.
      session_paths: session_paths,
      # How many moved to advisory, and why, so the advisory pile does not
      # absorb them silently. A gate that stops blocking has to say so.
      unattributed_count: length(unattributed),
      # Whether a rerun is actually running, as opposed to how old the newest
      # result is. The message used to assert the first from the second and got
      # it wrong in both directions.
      in_flight: Analysis.in_flight(scope),
      # And how long it has been running. "A rerun is in flight" is the same
      # sentence on every stop inside one run's window, so taking the advice
      # promptly returns a byte-identical block — which is what a livelock looks
      # like from the outside, and the opposite response is correct for each.
      in_flight_since: Analysis.in_flight_since(scope),
      # And whether anyone is watching at all. "No rerun is in flight, stopping
      # again enqueues one" is a claim about the world, and an untracked project
      # cannot support it — nothing would report a run either way.
      tracked?: Analysis.in_flight_state(scope) != :untracked,
      # Whose story each spex finding belongs to.
      #
      # Rule 3 of story 895: a working copy surfaces every finding about it,
      # regardless of assignment — loud everywhere, and the response says who
      # owns it rather than hiding it. Nothing here demotes anything; the latch
      # still decides what blocks. This only supplies the sentence that tells an
      # agent whether the red spex it is holding is its own work, the shared
      # backlog's, or another checkout's.
      story_assignment: story_assignments(scope, blocking ++ advisory, scope_context),
      # Which harness to wait on, so "a rerun is in flight" can name a way to
      # wait for it rather than only telling the agent to stop again.
      #
      # `Hooks.Stop` already has this remedy: when analysis is pending it hands
      # over `POST /api/harnesses/<id>/analysis/wait`, which blocks until the
      # sweep lands. But that path is only reached when validation *passed* —
      # a blocking result returns before it, so the case where waiting matters
      # most is the one case that never heard about the endpoint (5e9fa939:
      # three consecutive stops blocked on the same findings while a spex run
      # grew from 0s to 5m15s, each told to stop again).
      working_copy_id: scope.active_working_copy_id
    )
  end

  # When each stale source last finished, and how long it took to get there.
  #
  # "Stale" alone cannot tell "a rerun is coming" from "no rerun can land", and
  # those need opposite responses: wait, or stop editing and report the
  # analyzer. A source that last ran two minutes ago is mid-cycle; one that last
  # ran forty minutes ago, across several stops, is not coming back on its own.
  #
  # The duration adds a third condition the age alone cannot express. A run is
  # fingerprinted when it is enqueued and judged against the tree when it is
  # read, so an edit landing inside its window makes the result stale the
  # instant it arrives. For exunit and spex here — measured at 2m20s and 2m35s
  # against compiler's 9s — that is the normal working rhythm, not an anomaly,
  # and it produced "stale, last ran 0s ago" on a run that had just succeeded.
  # Waiting cannot fix it, so the message must not advise it.
  #
  # Both read the latest run that *answered*, which is the run staleness is
  # computed from. This used `Analysis.status/1`, whose `latest_full_runs/1`
  # includes `:failed` — so the age described one run while "stale" described
  # another, and the failure is usually the newer of the two.
  #
  # Measured on the live ledger: spex last completed at 03:59:05 and last failed
  # at 04:02:52, so a source whose real answer was four minutes stale reported
  # the failure's age instead. Everything keyed to that age then inverts —
  # mid-cycle rather than wedged, wait rather than escalate — and `83cde34f`
  # read the resulting "last ran 5m ago" against a 96-minute-old answer as
  # another working copy's run leaking in. It needs no second checkout.
  #
  # Per-source rather than one pass, which is also cheaper here:
  # `latest_completed_run/2` is an indexed lookup, where `status/1` computes
  # `Fingerprint` over every file row in the working copy — 4,544 on this
  # project — for an answer this does not use.
  #
  @doc """
  Public so the property can be asserted directly, the same reason
  `blocking_key/1` and `split_unattributed/2` are.
  """
  def run_timing(_scope, []), do: {%{}, %{}, %{}}

  def run_timing(scope, sources) do
    Enum.reduce(sources, {%{}, %{}, %{}}, fn source, {ages, durations, overtaken} ->
      run = Analysis.latest_answer(scope, source)

      {Map.put(ages, source, finished_at(run)), Map.put(durations, source, duration(run)),
       Map.put(overtaken, source, overtaken?(run))}
    end)
  end

  @doc """
  Why a source that has never produced an answer could not run.

  Only for sources with no completed run at all. A source with an older answer
  is behind, which is a different condition and already described; this one has
  nothing, and the footer said so as "stale, has never completed" — true, and
  silent about the cause.

  The cause is already in the ledger. `Reconciler.fail/2` writes the analyzer's
  own words to `Run.output`, and nothing read them back. `6f89b278` is three
  days of blocked stops where the answer sat in that column the whole time:

      This working copy's test database is 2 migration(s) behind.
      Pending: 20260811120000_conversation_messages_record_origin, …
      Run `MIX_TEST_PARTITION=had8804a9s MIX_ENV=test mix ecto.migrate`

  The agent instead saw 22 stale spex findings from stories it had never
  touched, and advice to stop again — which re-entered the same block. It read
  another team's provisioning specs looking for a defect that was a missing
  database.

  Truncated because an analyzer that dies mid-suite can write a great deal, and
  this rides in a stop response with a byte cap. The first lines are where these
  tools put the sentence that matters.
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

  # A run that never produced output at all.
  #
  # `Reconciler.fail/2` writes the reason to `stats["error"]`, not to `output` —
  # `output` is what the *tool* printed, and an analyzer that crashed before
  # starting printed nothing. So the two failure shapes land in different
  # columns and only one was ever read back.
  #
  # `639d0fc1` is the cost. An un-onboarded working copy made credo crash
  # before it ran, 104 times across two checkouts, with the reason recorded
  # every time:
  #
  #     credo crashed: /Users/…/intake-on-home has no recorded test partition,
  #     so it has not been onboarded. Run: mix harness.onboard
  #
  # What the agent got instead was the previous run's findings, correctly
  # labelled stale, on a file it had already fixed and verified clean — the
  # same finding three times, still citing a line number from before the edit
  # that shifted it. The remedy offered was "stop again and let a rerun replace
  # these", and the rerun crashed identically. Nothing it could edit was ever
  # measured.
  #
  # The information was one process away the whole time and the agent had no
  # reason to look for it. It is the second analyzer that week to fail an unmet
  # precondition and surface it as stale findings — spex did the same through
  # the migration guard (`6f89b278`) — which is why this reads the column
  # rather than the instance.
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
  moment that result was produced and the answer would drift if asked later.
  `d9f0846c`: a fix to the analyzer is not in force until the harness is
  rebuilt, and from inside the stop loop that is indistinguishable from an
  ordinary stale finding — three loops were spent on findings already fixed
  while the compiled pipeline sat eleven commits behind.
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

  # Did an edit land while this run was in flight?
  #
  # `input_fingerprint` is stamped at enqueue and `completed_fingerprint` at
  # reconcile, so the two differ exactly when the tree moved underneath it. That
  # is the difference between a result waiting will refresh and one no amount of
  # waiting can, and the two take opposite advice.
  #
  # The renderer inferred this from the run's duration — a result younger than
  # the run took must have been overtaken — which is sound only if nothing was
  # edited after the run finished. A stop that follows a long run closely breaks
  # that: the edit came afterwards, a rerun would be clean, and the message said
  # not to bother waiting for one.
  #
  # `nil` for a run predating the column, which is what sends the renderer back
  # to the duration inference rather than asserting either answer.
  defp overtaken?(%{input_fingerprint: input, completed_fingerprint: done})
       when is_binary(input) and is_binary(done),
       do: input != done

  defp overtaken?(_run), do: nil

  defp finished_at(%{finished_at: %DateTime{} = at}), do: at
  defp finished_at(_), do: nil

  # Nil rather than zero when either end is missing: zero would read as an
  # instant run and send the message down the "your edit predates this" branch,
  # which is the wrong half of the very distinction this exists to draw.
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

        {enforced, unenforced} = split_by_story_enforcement(source, problems, scope_context)

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

  # Spex enforcement is per-story, and it runs BEFORE the configured mode
  # rather than as another mode. A story that has never gone green is
  # *supposed* to be red — its specs are the contract driving the
  # implementation that hasn't been written yet. Blocking on that is what
  # kept `ProjectConfiguration.spex` pinned at `:off`.
  #
  # Demoted problems stay advisory rather than being dropped: the failure
  # is still real and still belongs on the Problems page, it just isn't
  # the agent's problem yet.
  #
  # Every other source is story-agnostic and passes through untouched.
  # The criterion says which story it belongs to. The filename does not.
  #
  # This read the leading number out of `test/spex/<n>_.../` and treated it as a
  # story id. Those numbers are directory names and have drifted from the ids:
  # measured on this project, `811_user_sees_the_agents_task_queue_at_a_glance`
  # derives 811 — a real story, "Onboarding lives at /app", `specs_ready` false
  # — while the story with that title is 862, `specs_ready` true. So a latched
  # story gated nothing (no path derives 862) and an unlatched one gated spex
  # that were not its own.
  #
  # Both wrong answers are silent, because a number that resolves to *a* story
  # looks exactly like one that resolves to the right story. A missing story
  # would have hit the `nil` branch and been loud.
  #
  # `criteria.spec_path` is the recorded answer — `claim_spec_paths/2` writes it
  # when a spex file is created, which is why it survives a rename. 22 of this
  # project's 25 spex problems join on it exactly.
  #
  # The filename parse stays as the fallback for a spex no criterion claims.
  #
  # An orphan blocks. That was an open question here — "there is no right answer
  # for an orphan" — and it is settled: block *because* it is orphaned. The
  # argument for the other side is that an unlatched spex should not block, and
  # an orphan is unlatched by definition; the argument against, which wins, is
  # that a spex whose story link has broken would then go quiet instead of loud,
  # and a real regression could hide behind it. A broken link should surface as
  # a block, not as silence.
  #
  # That fallback now resolves what it parses. The directory name is the story's
  # durable **number**, and it used to be handed straight to a set of primary
  # keys — the comparison above, made from the wrong end. Going through
  # `story_ids_by_number` means an unmatched number answers `nil` and lands in
  # the loud branch instead of quietly naming whichever story holds that id.
  @doc """
  The subset of `problems` this gate would actually enforce.

  Public so `Hooks.AnalysisAlert` can count the same population the gate blocks
  on rather than everything recorded. Reused rather than reimplemented, because
  two copies of "what counts as enforceable" drift, and the drift is silent —
  the alert would report a number the gate disagrees with and nobody would see
  which was wrong.

  Costs three reads, so it is only worth calling once something has landed. The
  alert's silent path never reaches here.
  """
  @spec enforceable(Scope.t(), [Problems.Problem.t()]) :: [Problems.Problem.t()]
  def enforceable(%Scope{} = scope, problems) do
    ctx = %{
      specs_ready_story_ids: specs_ready_story_ids(scope),
      criterion_story_ids: AcceptanceCriteria.spec_path_story_ids(scope),
      spec_file_story_ids: Files.bdd_spec_story_id_by_path(scope),
      story_ids_by_number: Stories.list_story_ids_by_number(scope)
    }

    problems
    |> Enum.group_by(& &1.source)
    |> Enum.flat_map(fn {source, of_source} ->
      {enforced, _advisory} = split_by_story_enforcement(source, of_source, ctx)
      enforced
    end)
  end

  defp split_by_story_enforcement("spex", problems, ctx) do
    %{
      specs_ready_story_ids: ready_ids,
      criterion_story_ids: by_path,
      spec_file_story_ids: by_spec_file,
      story_ids_by_number: by_number
    } = ctx

    Enum.split_with(problems, fn problem ->
      case story_id_for(problem.file_path, by_path, by_spec_file, by_number) do
        nil -> true
        story_id -> MapSet.member?(ready_ids, story_id)
      end
    end)
  end

  defp split_by_story_enforcement(_source, problems, _ctx), do: {problems, []}

  # Assignment does NOT exempt a spex finding, and criterion 2406 is why.
  #
  # This used to also require the story to be assigned to this checkout, on the
  # same reasoning `issues_resolved` uses: a gate whose passing state depends on
  # work outside the gated unit is a wall, and an agent on the war-epic copy was
  # shown 21 findings from an epic assigned to the main checkout.
  #
  # But `specs_ready` already answers that. The latch is *earned* — set when a
  # story's specs have gone green — so a finding that survives it is a
  # regression on proven behaviour, not somebody else's unfinished work. 2406
  # states the consequence directly: "an exemption this wide would let a broken
  # build through on every checkout that did not happen to own it."
  #
  # So the two guards are not both needed, and only one is right. Unready
  # stories are held back by the latch, which is what stopped those 21 findings;
  # ready ones block whoever is stopping, wherever they are assigned.

  # Criteria first, then the file row, then the directory name.
  #
  # The last of those is a guess and was doing most of the work. Spex
  # directories are named from `story.number` in some projects and `story.id` in
  # others, so `derive_story_number/1` hands back an id where a number is
  # expected, the lookup misses, and the problem lands in the `nil` branch —
  # which enforces. An unwritten feature's red spec then blocks a stop as though
  # it were a regression, and the agent is shown a backlog with no owner.
  #
  # Broken Oaths on 2026-09-08: 38 of 54 directories id-named, and 90 of 145
  # spex problems enforced this way over features nobody had written yet.
  #
  # `files.story_id` is resolved at sync time from the spec itself and was
  # correct for every directory of both conventions, so it goes ahead of the
  # parse. The parse stays last rather than being deleted: a spec file that has
  # not been synced yet has no row, and a directory name is better than nothing
  # there.
  defp story_id_for(file_path, by_path, by_spec_file, by_number) do
    Map.get(by_path, file_path) ||
      Map.get(by_spec_file, file_path) ||
      story_id_from_path(file_path, by_number)
  end

  defp story_id_from_path(file_path, by_number) do
    case Parser.derive_story_number(file_path) do
      nil -> nil
      number -> Map.get(by_number, number)
    end
  end

  defp specs_ready_story_ids(scope) do
    scope
    |> Stories.list_specs_ready_story_ids()
    |> MapSet.new()
  end

  # `%{file_path => :mine | :unassigned | {:elsewhere, label}}` for spex
  # findings whose story can be identified.
  #
  # Spex only, because it is the only source with a story behind it — a credo
  # finding is about a file and has no owner in this sense. Paths that resolve
  # to no story are absent rather than `:unassigned`: "nobody has claimed this
  # story" and "this path is not a story's spex at all" are different facts, and
  # reporting the second as the first would tell an agent a directory is
  # unassigned work.
  #
  # The label is the destination checkout's, so the sentence can name where the
  # work is rather than printing a uuid at somebody.
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

  # A project nobody has assigned anything on gets no note at all.
  #
  # "This story is unassigned" is only worth saying where assignment is in
  # use — everywhere else it is true of every story in the project and
  # tells the reader nothing, while adding a paragraph to every stop. The
  # axis lands empty and changes nothing, and that has to include the
  # wording.
  defp story_assignments_for(_paths, assigned, _mine, _labels, _by_path, _by_number)
       when assigned == %{},
       do: %{}

  defp story_assignments_for(paths, assigned, mine, labels, by_path, by_number) do
    for path <- paths,
        story_id = Map.get(by_path, path) || story_id_from_path(path, by_number),
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

  defp decide([], [], _stale, _opts), do: {:ok, nil}

  # Nothing blocks, and something is still worth saying.
  #
  # Story 895's rule 3: a working copy surfaces every finding about it,
  # regardless of assignment. An allowed stop used to say nothing at all, so a
  # finding on another checkout's story — advisory, correctly, because its specs
  # have never gone green — was invisible to the agent standing in the checkout
  # where it failed. Invisible is the one thing the rule rules out; the point of
  # assignment is that the finding is *reported* here and *refused* elsewhere.
  #
  # Only the assignment sentence, and only when there is one. A list of advisory
  # findings on every allowed stop is the wallpaper failure `Analysis.Alert`
  # already argues against — an agent that reads a paragraph it cannot act on
  # learns to skip the paragraph.
  defp decide([], advisory, _stale, opts) do
    Logger.warning("[Validation] #{length(advisory)} advisory problem(s) not blocking")

    {:ok, Problems.advisory_assignment_note(advisory, Keyword.get(opts, :story_assignment, %{}))}
  end

  defp decide(blocking, advisory, stale_sources, opts) do
    if stale_sources != [] do
      Logger.info("[Validation] blocking on stale sources: #{Enum.join(stale_sources, ", ")}")
    end

    reason =
      Problems.render_stop_response(
        blocking,
        advisory,
        # `:internal_agent?` is already here, set by `check_blocking_problems/5`
        # from the opts that carry the identity. It decides two things the
        # renderer cannot work out for itself: that this agent is not the one
        # waiting on the rerun (story 988; the hook's "curl analysis/wait, then
        # stop again" has no counterpart here, and QA watched an agent obey it
        # and spend a whole turn re-curling — issue `778ab035`), and that its
        # edits are not unattributed but simply its own.
        Keyword.put(opts, :stale_sources, stale_sources)
      )

    {:error, reason, blocking_key(blocking)}
  end

  # What is blocking, as something that can be compared across stops.
  #
  # Deliberately not the rendered reason. R8's repeat detection hashes the text
  # it is given, and this text carries relative ages — "stale, last ran 3
  # minutes ago" — which change on every stop. Hashing it would produce a new
  # value each time and the streak would never build, so the escape would be
  # silently inert in exactly the case that needs it most: an analyzer lagging
  # while the same findings block turn after turn.
  #
  # The findings themselves are stable. A fixed problem, a new one, or a moved
  # line all change this; waiting does not.
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
