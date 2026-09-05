defmodule CodeMySpec.Problems.ProblemRenderer do
  @moduledoc """
  Utility module for rendering Problem structs into human and AI-readable formats.
  Transforms normalized problems from static analysis tools, compilers, and test
  failures into actionable feedback strings for Claude Code agent evaluation hooks.
  """

  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Utils.Utf8

  @severity_order [:error, :warning, :info]

  # Compactness policy for stop-hook responses. The agent's context window
  # is finite — the response must stay tight.
  @per_problem_cap 200
  @per_source_list_cap 10
  @total_response_cap 4096

  @doc """
  Render a single problem to a formatted string.

  ## Options

    * `:format` - Output format: `:text` (default), `:compact`
    * `:include_source` - Include source tool name (default: true)
    * `:compact_message` - When true, strip multi-line message bodies
      (stacktraces, assertion left/right dumps) and keep only the first
      line. Default: false.
    * `:max_length` - Truncate the rendered line to this many bytes
      (ellipsis appended). Default: nil (no cap).

  """
  @spec render(Problem.t(), keyword()) :: String.t()
  def render(%Problem{} = problem, opts \\ []) do
    format = Keyword.get(opts, :format, :text)

    case format do
      :compact -> render_compact(problem, opts)
      :text -> render_text(problem, Keyword.get(opts, :include_source, true))
    end
  end

  @doc """
  Render a list of problems to a formatted string.

  ## Options

    * `:format` - Output format: `:text` (default), `:compact`, `:grouped`
    * `:group_by` - Grouping key for `:grouped` format: `:severity`, `:source`, `:file_path` (default: `:severity`)
    * `:include_summary` - Include problem count summary (default: true)

  """
  @spec render_list([Problem.t()], keyword()) :: String.t()
  def render_list(problems, opts \\ [])
  def render_list([], _opts), do: ""

  def render_list(problems, opts) do
    format = Keyword.get(opts, :format, :text)
    include_summary = Keyword.get(opts, :include_summary, true)
    group_by = Keyword.get(opts, :group_by, :severity)

    sorted = sort_problems(problems)

    rendered =
      case format do
        :grouped -> render_grouped(sorted, group_by, opts)
        _ -> render_flat(sorted, opts)
      end

    case include_summary do
      true -> render_summary(problems) <> "\n\n" <> rendered
      false -> rendered
    end
  end

  @doc """
  Render a summary of problem counts by severity.
  """
  @spec render_summary([Problem.t()]) :: String.t()
  def render_summary([]), do: "No problems found"

  def render_summary(problems) do
    counts = count_by_severity(problems)

    @severity_order
    |> Enum.map(fn severity -> {severity, Map.get(counts, severity, 0)} end)
    |> Enum.filter(fn {_severity, count} -> count > 0 end)
    |> Enum.map_join(", ", fn {severity, count} -> format_count(count, severity) end)
  end

  @doc """
  Render a summary of problem counts grouped by source tool, showing severity breakdown for each.
  """
  @spec render_summary_by_source([Problem.t()]) :: String.t()
  def render_summary_by_source([]), do: "No problems found"

  def render_summary_by_source(problems) do
    problems
    |> Enum.group_by(& &1.source)
    |> Enum.sort_by(fn {source, _} -> source end)
    |> Enum.map_join("\n", fn {source, source_problems} ->
      severity_summary = render_severity_counts(source_problems)
      "#{source}: #{severity_summary}"
    end)
  end

  @doc """
  Render problems as actionable feedback for Claude Code agent evaluation.

  ## Options

    * `:max_problems` - Maximum number of problems to include (default: 10)
    * `:context` - Context string to prepend (e.g., "Static analysis found issues:")

  """
  @spec render_for_feedback([Problem.t()], keyword()) :: String.t() | nil
  def render_for_feedback(problems, opts \\ [])
  def render_for_feedback([], _opts), do: nil

  def render_for_feedback(problems, opts) do
    max_problems = Keyword.get(opts, :max_problems, 10)
    context = Keyword.get(opts, :context)

    sorted = sort_problems(problems)
    total_count = length(problems)
    selected = Enum.take(sorted, max_problems)
    truncated_count = total_count - length(selected)

    parts = []

    parts =
      case context do
        nil -> parts
        header -> parts ++ [header]
      end

    parts = parts ++ [render_summary(problems)]
    parts = parts ++ [""]
    parts = parts ++ Enum.map(selected, &render_compact(&1, true))

    parts =
      case truncated_count > 0 do
        true -> parts ++ ["", "(#{truncated_count} more problems not shown)"]
        false -> parts
      end

    parts = parts ++ ["", "Please fix these issues and try again."]

    Enum.join(parts, "\n")
  end

  @doc """
  Render the full stop-hook `reason` string.

  Given the blocking and advisory problem lists, produces a compact
  string suitable for the agent's context window:

  - Each blocking problem is one line: `file:line — first-line message`
    truncated to `@per_problem_cap` bytes.
  - Per source, at most `@per_source_list_cap` blocking problems are
    enumerated; overflow surfaces as `... N more <source> problems
    (use get_issue to inspect)`.
  - Advisory problems are never enumerated — they collapse to one
    summary line per source: `<source>: N <severity>s on untouched
    scope (advisory)`.
  - The total response is capped at `@total_response_cap` bytes; excess
    is truncated with `... more problems omitted (response size limit)`.

  Returns `""` when there are no blocking problems — the allow path
  never produces a stop reason.
  """
  @spec render_stop_response([Problem.t()], [Problem.t()], keyword()) :: String.t()
  def render_stop_response(blocking, advisory, opts \\ [])

  def render_stop_response([], _advisory, _opts), do: ""

  def render_stop_response(blocking, advisory, opts) do
    stale = opts |> Keyword.get(:stale_sources, []) |> MapSet.new()
    last_ran = Keyword.get(opts, :last_ran, %{})
    run_duration = Keyword.get(opts, :run_duration, %{})
    overtaken = Keyword.get(opts, :overtaken, %{})
    reproduce = Keyword.get(opts, :reproduce_commands, %{})
    session_paths = Keyword.get(opts, :session_paths)

    # One fact, read once, answering two questions.
    #
    # An agent running inside our own BEAM has no session and never will, and
    # that changes both halves of the footer: it is not the one waiting on the
    # rerun, and it is not failing to attribute its edits — it owns the whole
    # checkout by design. Threaded as a single value because the two readings
    # cannot legitimately disagree.
    internal? = Keyword.get(opts, :internal_agent?, false)
    # One value rather than three positional arguments threaded four levels
    # down: they are only ever read together, and every question the footer asks
    # is about the same thing — what analysis is doing right now.
    #
    # `since` may be missing a source that is in `sources`. Locally executed
    # projects report names without start times, so "running, length unknown" is
    # a real state and not a bug.
    flight = %{
      sources: Keyword.get(opts, :in_flight, []),
      since: Keyword.get(opts, :in_flight_since, %{}),
      # Defaults true: every existing caller was making the "no rerun" claim
      # already, and only a caller that knows otherwise should soften it.
      tracked?: Keyword.get(opts, :tracked?, true),
      # The harness whose `analysis/wait` will block until the sweep lands, when
      # there is one to name. A scope with no harness gets the plain instruction
      # rather than a URL that would 404 — same rule as `Hooks.Stop`.
      working_copy_id: Keyword.get(opts, :working_copy_id),
      # Whether somebody else is already waiting on this run. Defaults false,
      # because every caller until story 988 was an agent that had to wait for
      # itself.
      orchestrator_waits?: internal?
    }

    header = "Fix these problems before stopping:\n\n"

    advisory_section =
      render_advisory_section(advisory, Keyword.get(opts, :unattributed_count, 0))

    runs = %{
      last_ran: last_ran,
      duration: run_duration,
      overtaken: overtaken,
      failures: Keyword.get(opts, :run_failures, %{}),
      analyzer_staleness: Keyword.get(opts, :analyzer_staleness, %{})
    }

    blocking_section = render_blocking_section(blocking, stale, runs, reproduce, session_paths)

    raw =
      header <>
        blocking_section <>
        advisory_section <>
        assignment_note(blocking, advisory, Keyword.get(opts, :story_assignment, %{})) <>
        stale_footer(blocking, stale, last_ran, run_duration, flight, overtaken) <>
        attribution_note(session_paths, internal?)

    enforce_total_cap(raw, blocking, advisory)
  end

  @doc """
  What an allowed stop says about findings that are not blocking it.

  Nothing blocked, so there is no findings list to hang a sentence under — which
  is exactly the gap. Story 895's rule 3 says a working copy surfaces every
  finding about it regardless of assignment, and until this an allowed stop said
  nothing at all: a red spex on another checkout's story is advisory here,
  correctly, and the agent standing in the checkout where it failed never heard
  of it.

  So this names them, one line each, with whose story each one is. `nil` when
  there is nothing to say, so the caller can send no message rather than an
  empty one.

  Only the ones with an owner to report. A finding whose story is this
  checkout's own is left out — an agent does not need telling that its own work
  is its own — and `Validation` supplies no assignments at all on a project
  where nobody has assigned anything, so an ordinary project sees none of this.
  That is the guard against the wallpaper failure `Analysis.Alert` argues
  against: a paragraph on every stop that nobody can act on is one the model
  learns to skip.
  """
  @spec advisory_assignment_note([Problem.t()], map()) :: String.t() | nil
  def advisory_assignment_note(advisory, assignment) when map_size(assignment) > 0 do
    lines =
      advisory
      |> Enum.filter(&is_binary(&1.file_path))
      |> Enum.uniq_by(& &1.file_path)
      |> Enum.flat_map(fn problem ->
        case Map.get(assignment, problem.file_path) do
          {:elsewhere, label} -> ["  - #{problem.file_path} — assigned to #{label}"]
          :unassigned -> ["  - #{problem.file_path} — assigned to no checkout"]
          _ -> []
        end
      end)
      |> Enum.take(@per_source_list_cap)

    case lines do
      [] ->
        nil

      lines ->
        "Not blocking this stop, and still true here:\n" <>
          Enum.join(lines, "\n") <>
          "\n\nThey failed in this working copy, which is why you are seeing them. " <>
          "Work assigned to another checkout is that checkout's to fix; work assigned " <>
          "to none is everybody's, including yours."
    end
  end

  def advisory_assignment_note(_advisory, _assignment), do: nil

  # Who owns the stories behind these spex findings.
  #
  # Story 895's third rule: a working copy surfaces every finding about it,
  # regardless of assignment. Nothing is hidden and nothing is demoted — what
  # changes is that the response says whose work each one is, so an agent
  # holding a red spex can tell "mine", "nobody's, so mine too" and "another
  # checkout's" apart. Before this they read identically, and the only available
  # reading was the discouraging one.
  #
  # Deliberately not a blocking decision. `specs_ready` still decides that, and
  # it is the right gate: the latch is earned by a green run, so a red spex on a
  # latched story is a regression whoever is stopping should care about — story
  # 895's own rule 4, and 983's "blocks any agent in the working copy". This
  # paragraph is orientation, not an escape hatch.
  #
  # Covers blocking and advisory together, because the sentence an agent needs
  # most is about a finding that did *not* block: "assigned elsewhere, listed
  # here, not yours to fix" is exactly the case that used to read as being stuck
  # behind somebody.
  defp assignment_note(_blocking, _advisory, assignment) when map_size(assignment) == 0, do: ""

  defp assignment_note(blocking, advisory, assignment) do
    paths =
      (blocking ++ advisory)
      |> Enum.map(& &1.file_path)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    elsewhere =
      for path <- paths, match?({:elsewhere, _}, Map.get(assignment, path)), uniq: true do
        {:elsewhere, label} = Map.get(assignment, path)
        label
      end

    unassigned = Enum.filter(paths, &(Map.get(assignment, &1) == :unassigned))

    case {elsewhere, unassigned} do
      {[], []} ->
        ""

      {[], some} ->
        "\n\n#{length(some)} of these #{if length(some) == 1, do: "is", else: "are"} on " <>
          "stories assigned to no checkout at all. Unassigned work belongs to every " <>
          "working copy rather than to none, so #{if length(some) == 1, do: "it is", else: "they are"} " <>
          "yours as much as anybody's."

      {labels, []} ->
        "\n\nSome of these belong to stories assigned to #{join_labels(labels)}. They are " <>
          "listed here because this checkout is where they failed, not because they are " <>
          "yours to fix."

      {labels, some} ->
        "\n\nSome of these belong to stories assigned to #{join_labels(labels)} — listed " <>
          "here because this is where they failed, not because they are yours. " <>
          "#{length(some)} other#{if length(some) == 1, do: "", else: "s"} sit on stories " <>
          "assigned to no checkout at all, which makes them everybody's, including yours."
    end
  end

  defp join_labels([one]), do: one
  defp join_labels([a, b]), do: "#{a} and #{b}"
  defp join_labels(many), do: Enum.join(many, ", ")

  # `runs` carries what the ledger says about each source — age, duration,
  # whether an edit landed inside the window, and why it never completed. One
  # value rather than four positional arguments threaded two levels down, for
  # the same reason `flight` is one: they are only ever read together, and the
  # list was already seven long.
  defp render_blocking_section(blocking, stale, runs, reproduce, session_paths) do
    blocking
    |> Enum.group_by(& &1.source)
    |> Enum.sort_by(fn {source, _} -> source end)
    |> Enum.map_join("\n", &render_blocking_group(&1, stale, runs, reproduce, session_paths))
  end

  defp render_blocking_group({source, items}, stale, runs, reproduce, session_paths) do
    %{last_ran: last_ran, duration: run_duration, overtaken: overtaken, failures: failures} = runs
    count = length(items)
    visible = Enum.take(items, @per_source_list_cap)

    details = Enum.map_join(visible, "\n", &render_blocking_line(&1, session_paths))

    overflow =
      case count - length(visible) do
        0 -> ""
        n -> "\n  ... #{n} more #{source} problems (use get_issue to inspect)"
      end

    marker = stale_marker(source, stale, last_ran, run_duration, overtaken, failures)

    "#{source} (#{count})#{marker}:\n#{details}#{overflow}" <>
      reproduce_line(source, reproduce) <>
      killed_note(items) <>
      foreign_spex_note(source, items, session_paths) <>
      precondition_note(items) <>
      stale_build_note(source, runs)
  end

  # The one case where "stop again and let a rerun replace these" is wrong for a
  # reason the reader cannot see: the rerun will run the same old code.
  #
  # A harness runs the analyzer it booted with, so a fix to `StaticAnalysis` is
  # not in force until it is rebuilt. `d9f0846c` measured three stop-hook loops
  # spent on findings already fixed, while the compiled pipeline sat eleven
  # commits behind for a whole session. The response said "stale, a rerun is in
  # flight" — true, and useless — and rendered identically both to an ordinary
  # stale finding and to the real defect it was masking, so each time the
  # diagnosis stopped at the first plausible cause. Recovering it needed a
  # `.beam` timestamp.
  #
  # On the source's own group rather than in the footer: one analyzer can be
  # behind while another is current, and the advice differs for each.
  defp stale_build_note(source, %{analyzer_staleness: notes}) do
    case Map.get(notes, source) do
      note when is_binary(note) -> "\n  Analyzer build: #{note}."
      _ -> ""
    end
  end

  defp stale_build_note(_source, _runs), do: ""

  # Why a spex still blocks after being marked as somebody else's.
  #
  # `(not edited by this session)` means "advisory, demoted" on every other
  # source — `split_unattributed/2` moves those out of the blocking set. Spex is
  # exempt (`@attribution_exempt_sources`), so the identical marker sits on a
  # finding that is still blocking, and nothing in the response distinguishes
  # the two readings.
  #
  # The exemption is right, and so is the block. `specs_ready` is not set
  # optimistically by anyone — the specs-passing gate sets it on a fresh green
  # run and `clear_specs_ready_on_readiness_change/1` clears it whenever the
  # story is released or parked. So a red spex on a latched story is a story
  # whose specs went green and have since gone red: a regression in this working
  # copy, which is a different thing from somebody's in-flight work and is why
  # attribution must not demote it.
  #
  # What the agent is missing is that sentence. It is holding a red spex in a
  # file it never touched, and the only reading available from the response is
  # "somebody else's problem, and I am stuck behind it" — which is the bind
  # `b9a9f9bc` describes, and which cost story 985 four unrelated sessions
  # before anyone traced it.
  #
  # Only when there is a foreign finding to explain, and only for spex: an agent
  # looking at its own red spex does not need a paragraph about latches.
  defp foreign_spex_note("spex", items, %MapSet{} = session_paths) do
    foreign? =
      MapSet.size(session_paths) > 0 and
        Enum.any?(items, fn
          %Problem{file_path: path} when is_binary(path) ->
            not MapSet.member?(session_paths, path)

          _ ->
            false
        end)

    case foreign? do
      true ->
        "\n  A red spex blocks even in a file this session did not touch — spex is " <>
          "the one source attribution does not demote. That is because the latch " <>
          "making it blocking is earned, not asserted: `specs_ready` is set by a " <>
          "green spex run and cleared when the story is released or parked. So " <>
          "these went green once, and something has changed since. Usually that is " <>
          "a regression in this working copy; it can also be a precondition this " <>
          "checkout does not have — see any note below. Fix it, or if the story is " <>
          "genuinely mid-rework, park it — changing `ready_for_dev` clears the " <>
          "latch and these stop blocking."

      false ->
        ""
    end
  end

  defp foreign_spex_note(_source, _items, _session_paths), do: ""

  # A group whose every finding is a killed process is reporting on the machine,
  # not on the code, and nothing else in this footer can say so. `** (EXIT …)
  # killed` is a process being terminated — never an assertion — so a suite that
  # was killed under load arrives looking exactly like a suite that failed.
  #
  # Measured over four consecutive stops: twelve distinct findings, a different
  # set each sweep including a different *line* of the same file, every one of
  # them passing standalone in seconds. Load 6–8.5, two agents and the harness
  # driving suites through one `_build/test`.
  #
  # The advice is what makes it expensive rather than merely noisy. "Stop again
  # and let the rerun replace these" is correct — the rerun does land, and does
  # replace them — with another random set, at a rate that has nothing to do
  # with the code. Followed as instructed it produces a fresh block every couple
  # of minutes forever, and the only exit is `clear_problems`, which requires
  # already knowing what `killed` means.
  #
  # All rather than any: one killed process beside three real failures is a run
  # that mostly worked, and calling that environmental would hide the three.
  defp killed_note([]), do: ""

  defp killed_note(items) do
    case Enum.all?(items, &killed?/1) do
      true ->
        "\n  (#{killed_subject(length(items))} the machine, not the code: check load " <>
          "and concurrent runs, and clear these rather than editing anything.)"

      false ->
        ""
    end
  end

  # "all 1 are killed processes" is what counting without reading produces, and
  # it lands in front of every agent that hits this.
  defp killed_subject(1),
    do:
      "this is a killed process, not an assertion — the suite was terminated rather than failing. That is"

  defp killed_subject(n),
    do:
      "all #{n} are killed processes, not assertions — the suite was terminated rather than failing. That is"

  defp killed?(%Problem{message: message}) when is_binary(message),
    do: message =~ ~r/\*\* \(EXIT from #PID<[^>]+>\) killed/

  defp killed?(_problem), do: false

  # A criterion that never reached its assertions has not regressed.
  #
  # `d145faae`: `docker/fleet/keys/fleet` is gitignored and generated by
  # `docker/fleet/fleet.sh up` into whichever working copy ran it, so every
  # criterion needing the fleet box is unpassable in every other checkout —
  # while the fleet itself runs fine. `CodeMySpecSpex.Case.fleet_box/1` raises
  # before any assertion executes, deliberately, because a criterion that
  # quietly passed without running the commands it is about would be the worse
  # failure.
  #
  # The block is machine-wide: on this machine five worktrees were held by a
  # precondition living in one. And the footer told the agent it was a
  # regression here and to fix it or park the story — fixing is impossible from
  # the wrong checkout, and parking means changing `ready_for_dev` on someone
  # else's story to unblock your own session, which is the worst move available
  # and the one the wording nudged toward.
  #
  # Counted rather than all-or-nothing, unlike `killed_note/1`. A killed process
  # says nothing about which finding it replaced, so a mixed group there is a
  # run that mostly worked; an unmet precondition is identifiable per finding,
  # so naming how many is both safe and more useful than a verdict on the group.
  defp precondition_note([]), do: ""

  defp precondition_note(items) do
    items
    |> Enum.filter(&missing_precondition?/1)
    |> precondition_sentence(length(items))
  end

  defp precondition_sentence([], _total), do: ""

  defp precondition_sentence(blocked, total) do
    "\n  (#{length(blocked)} of #{total} never reached an assertion — they need a " <>
      "local precondition this checkout does not have, and each names it and how to " <>
      "create it. Not a regression here: bring the precondition up, or run from the " <>
      "checkout that has it. No edit in this working copy can clear them.)"
  end

  # Matched on the raise, not on a story or a path, so a second precondition
  # written the same way is covered without touching this.
  defp missing_precondition?(%Problem{message: message}) when is_binary(message),
    do: message =~ ~r/No fleet key at /

  defp missing_precondition?(_problem), do: false

  # How to see these yourself. Only where the gate's command and the obvious
  # one disagree — credo, whose plain invocation hides the low-priority band
  # these are promoted from — so this stays a fact worth reading rather than
  # noise appended to every group.
  # The `{command, why}` form also says why the obvious command was wrong.
  # Handing an agent a longer command it did not ask for reads as pedantry
  # unless it knows its own green was false: `mix credo` prints "Showing
  # priority issues: ↑ ↗ →" and suppresses the band these are promoted from, so
  # it says the file is clean while the gate blocks on it. Measured on
  # `context_design_review.ex:20` — 0 findings plain, 1 with the gate's args, no
  # config difference (14f141c1).
  defp reproduce_line(source, reproduce) do
    case Map.get(reproduce, source) do
      {command, why} when is_binary(command) and command != "" ->
        "\n  reproduce: #{command}" <> why_line(why)

      command when is_binary(command) and command != "" ->
        "\n  reproduce: #{command}"

      _ ->
        ""
    end
  end

  defp why_line(why) when is_binary(why) and why != "", do: "\n  (#{why})"
  defp why_line(_why), do: ""

  # Marked, not dropped: dropping opens an escape at the last stop of a run
  # and hides an analyzer that fails every time.
  #
  # With an age, because "stale" alone does not say whether waiting will help.
  # A source that last ran two minutes ago is mid-cycle; one that last ran
  # forty minutes ago has not been coming back, and the right response is to
  # report the analyzer rather than stop again. Those need opposite actions and
  # the message could not tell them apart.
  defp stale_marker(source, stale, last_ran, run_duration, overtaken, failures) do
    case {MapSet.member?(stale, source), Map.get(last_ran, source)} do
      {false, _} ->
        ""

      {true, %DateTime{} = at} ->
        " — stale, last ran #{ago(at)}#{run_window(source, at, run_duration, overtaken)}"

      {true, _} ->
        " — stale, has never completed" <> failure_clause(Map.get(failures, source))
    end
  end

  # Why it never completed, in the analyzer's own words.
  #
  # "has never completed" is true and says nothing about the cause, and the
  # cause is already in `Run.output` — `Reconciler.fail/2` writes it there and
  # nothing read it back. `6f89b278` is three days of blocked stops where the
  # answer sat in that column: a test database two migrations behind, and the
  # exact command for the right partition. What the agent saw instead was 22
  # stale spex findings from stories it had never touched, and advice to stop
  # again, which re-entered the same block.
  #
  # Indented under the group rather than folded into the marker: this is
  # somebody else's output, often multi-line, and running it into our sentence
  # is how a stack trace ends up reading like our own prose.
  defp failure_clause(nil), do: ""

  defp failure_clause(reason) do
    body = reason |> String.split("\n") |> Enum.map_join("\n", &("      " <> &1))
    "\n\n    The analyzer could not run. It said:\n\n" <> body <> "\n"
  end

  # Only when the run is slower than the age, which is the case the age alone
  # renders absurd: "stale, last ran 0s ago" on a run that had just succeeded.
  # It had not gone stale since finishing — the edit landed while it ran.
  defp run_window(source, at, run_duration, overtaken) do
    if overtaken?(source, at, run_duration, overtaken),
      do: " (run takes #{duration_text(Map.get(run_duration, source))})",
      else: ""
  end

  # The result was already answering about an older tree when it arrived.
  #
  # A run is fingerprinted at enqueue and judged against the tree when read, so
  # an edit inside its window makes it stale on completion. Comparing the age to
  # the duration is what separates that from an ordinary lag, and they take
  # opposite advice: one is fixed by waiting and one cannot be.
  # The ledger answers it where it can. `input_fingerprint` is stamped at
  # enqueue and `completed_fingerprint` at reconcile, so the two differ exactly
  # when the tree moved while the run was in flight — no inference involved.
  defp overtaken?(source, at, run_duration, overtaken) do
    case Map.get(overtaken, source) do
      answer when is_boolean(answer) -> answer
      nil -> overtaken_by_duration?(source, at, run_duration)
    end
  end

  # The fallback, for a run that finished before `completed_fingerprint` existed.
  # A result younger than the run took must have been overtaken — sound only if
  # nothing was edited after it finished, which a stop closely following a long
  # run breaks. Kept because guessing "not overtaken" for those rows would send
  # an agent to wait out a rerun that cannot come back fresh, and that is the
  # loop this whole branch exists to break.
  defp overtaken_by_duration?(source, %DateTime{} = at, run_duration) do
    case Map.get(run_duration, source) do
      seconds when is_integer(seconds) and seconds > 0 -> staleness_seconds(at) < seconds
      _ -> false
    end
  end

  defp overtaken_by_duration?(_source, _at, _run_duration), do: false

  defp duration_text(seconds) when seconds < 60, do: "#{seconds}s"
  defp duration_text(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)}m"
  defp duration_text(seconds), do: "#{div(seconds, 60)}m#{rem(seconds, 60)}s"

  defp ago(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      s when s < 90 -> "#{s}s ago"
      s when s < 5400 -> "#{div(s, 60)}m ago"
      s -> "#{div(s, 3600)}h ago"
    end
  end

  defp stale_footer(blocking, stale, last_ran, run_duration, flight, overtaken) do
    blocking
    |> Enum.map(& &1.source)
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(stale, &1))
    |> case do
      [] ->
        ""

      sources ->
        {ran, never} = Enum.split_with(sources, &match?(%DateTime{}, Map.get(last_ran, &1)))

        stale_sentence(ran) <>
          never_sentence(never) <>
          " Do not re-fix anything you have already corrected." <>
          escalation(sources, last_ran, run_duration, flight, overtaken)
    end
  end

  # "Stale" covers two conditions and they are not the same news.
  #
  # `Analysis.fresh?/2` answers false both when the newest completed full run
  # predates your edits *and* when there is no completed full run at all — a
  # source whose every run failed, which is ordinary for credo and spex. The
  # footer asserted the first for both, so a source that had never produced a
  # result was described as having "last ran before your most recent edit".
  #
  # That mattered in a report where exunit read current while credo and spex
  # read stale against the same edit: the two were not disagreeing about the
  # edit, they were in different conditions wearing one label, and the label
  # sent the reader looking for a comparison bug.
  defp stale_sentence([]), do: "\n\n"

  defp stale_sentence(sources),
    do:
      "\n\nSources marked stale (#{Enum.join(Enum.sort(sources), ", ")}) last ran " <>
        "before your most recent edit."

  defp never_sentence([]), do: ""

  defp never_sentence(sources) do
    " #{Enum.join(Enum.sort(sources), ", ")} #{verb(sources)} never completed a run, so " <>
      "#{pronoun(sources)} findings are whatever was recorded last — not a result " <>
      "measured against your edits."
  end

  defp verb([_]), do: "has"
  defp verb(_), do: "have"

  defp pronoun([_]), do: "its"
  defp pronoun(_), do: "their"

  # Two different facts, and they had been collapsed into one sentence.
  #
  # `last_ran` is the `finished_at` of the newest *completed* run, so its age
  # says how old the result is — not how long anything has been running. The old
  # wording said "has not completed in over N minutes", which reads as a run in
  # flight, and the line above it asserted "Analysis is running now" whether or
  # not anything was. An agent chasing a wedged analyzer found a run that had
  # completed in under three minutes, thirty-eight minutes earlier.
  #
  # So say the age, and say separately whether a rerun is actually in flight —
  # because that is what decides the advice. Waiting works when something is
  # running and never works when nothing is.
  defp escalation(sources, last_ran, run_duration, flight, overtaken) do
    age =
      sources
      |> Enum.map(&Map.get(last_ran, &1))
      |> Enum.map(&staleness_seconds/1)
      |> Enum.max(fn -> 0 end)

    rerunning = Enum.filter(sources, &(&1 in flight.sources))

    overtaken_sources =
      Enum.filter(sources, &overtaken?(&1, Map.get(last_ran, &1), run_duration, overtaken))

    # Checked before the others because it is the most specific condition and
    # the only one none of them describes. "A rerun is in flight, stop again"
    # and "stopping again enqueues one" are both advice to wait, and waiting is
    # what cannot work here — the next edit overtakes the rerun exactly as it
    # overtook this one.
    if overtaken_sources != [] do
      overtaken_sentence(overtaken_sources, run_duration, rerunning)
    else
      wait_or_report(age, rerunning, run_duration, flight)
    end
  end

  # Names the remedy, because neither of the two that exist is obvious and
  # neither is "fix it": get a sweep to land with no edit inside it, or act on
  # findings that are one edit behind. They are real results from a run that
  # succeeded — a coverage gap, not a wrong answer — and nothing here opens an
  # escape from them.
  #
  # "Pause edits until a sweep completes" was the first wording and it is wrong
  # with nothing in flight: it describes waiting for something that will not
  # start, because a stop is what enqueues a run. An agent following it edits
  # nothing and waits, which is the loop this exists to break wearing new words.
  # So the instruction is what the reader does — stop, and do not edit while it
  # runs — and the in-flight fact only changes whether that also enqueues one.
  defp overtaken_sentence(sources, run_duration, rerunning) do
    longest =
      sources
      |> Enum.map(&Map.get(run_duration, &1))
      |> Enum.filter(&is_integer/1)
      |> Enum.max(fn -> 0 end)

    " #{Enum.join(Enum.sort(sources), ", ")} #{verb(sources)} a run time of " <>
      "#{duration_text(longest)} and your edits landed inside it, so a rerun " <>
      "will finish stale as well. The analyzer is working — it answered about " <>
      "the tree it was given." <>
      next_sweep_sentence(sources, rerunning) <>
      " Or act on these as they stand: one edit behind is not the same as wrong."
  end

  defp next_sweep_sentence(sources, rerunning) do
    case Enum.filter(sources, &(&1 in rerunning)) do
      [] ->
        " Stopping again enqueues a sweep; let that one finish without editing " <>
          "during it and its result will be current."

      running ->
        " A sweep is in flight now (#{Enum.join(Enum.sort(running), ", ")}) — " <>
          "stop again without editing during it and its result will be current."
    end
  end

  defp wait_or_report(age, rerunning, run_duration, flight) do
    case {age, rerunning, flight.tracked?} do
      {_age, [_ | _] = running, _} ->
        " A rerun is in flight now (#{running_detail(running, run_duration, flight)})." <>
          wait_remedy(flight)

      # Nothing is watching, so "no rerun is in flight" is not something this
      # can know — `in_flight/1` answers the same empty list for idle and for
      # untracked. Saying the analyzer is failing on that basis sends the reader
      # after a component that may never have been started for this project.
      {_age, [], false} ->
        " Nothing is tracking analysis runs for this project, so whether one is " <>
          "in flight is unknown — not \"none\". Check that the analyzer is " <>
          "running for this working copy before concluding anything from these " <>
          "results' age."

      {age, [], true} when age > 900 ->
        " The newest of these results is #{div(age, 60)} minutes old and no rerun " <>
          "is running, so nothing is going to replace it on its own: treat the " <>
          "analyzer as failing and report it rather than editing around it."

      {_age, [], true} ->
        " No rerun is in flight. Stopping again enqueues one; if these persist " <>
          "across several stops with no change, the analyzer itself is failing — " <>
          "report that rather than editing around it."
    end
  end

  # Waiting, as something the agent can actually do.
  #
  # "Stop again and let it replace these" was the whole remedy, and it is a race
  # the agent loses: a stop is what it is being refused, so it re-stops
  # immediately, lands inside the same run, and is told the same thing. Three
  # consecutive stops on one set of findings while the run grew 0s → 4m42s →
  # 5m15s (5e9fa939). The instruction was not wrong, it was just faster than the
  # thing it was waiting for.
  #
  # `analysis/wait` blocks until the sweep lands, so following it once costs one
  # wait instead of N stops. `Hooks.Stop` has handed this out for the *pending*
  # case all along — the gap was that a blocking result returns before that
  # check, so the case where waiting matters most never heard about it.
  #
  # Run in the background: a sweep is 200-590s here and the agent is notified
  # when it returns, which is also why this is an HTTP endpoint rather than an
  # MCP tool (MCP caps a request at 30s).
  # An agent inside our own BEAM is not the one waiting.
  #
  # It stops, the analyzers run, and the orchestrator delivers the answer as a
  # message — so telling it to block on `analysis/wait` and stop again buys
  # nothing and costs a turn. QA of story 988 watched an agent take the advice
  # literally: it curled the endpoint, was notified, curled it again, and spent
  # the turn on it. Above the general clause because it is the narrower match.
  defp wait_remedy(%{orchestrator_waits?: true}) do
    " You do not need to wait for it, or end another turn to find out — when the" <>
      " run lands you will be told what it found."
  end

  defp wait_remedy(%{working_copy_id: id}) when is_binary(id) do
    " Wait for it with `curl -sS -X POST localhost:4004/api/harnesses/#{id}/analysis/wait`" <>
      " — run that in the background and you will be notified when it returns — then" <>
      " stop again. Stopping again immediately lands inside the same run and returns this."
  end

  defp wait_remedy(_flight), do: " Let it finish, then stop again and it will replace these."

  #
  # The elapsed figure is the whole point: it is the only part of this footer
  # that changes between two stops inside one run's window, and without it
  # taking the advice — stop again, promptly — returns a byte-identical block.
  # Two identical blocks in a row is the signature of the livelock 1f60a145 was
  # about, where the promised rerun never came, and the correct response to that
  # is the opposite of the correct response here. Measured on the incident that
  # produced this: stops 13 seconds apart, both answered from the run before,
  # while the run they were told about finished clean 5 seconds later (020f573e).
  #
  # The typical duration comes from the last completed run of that source, so it
  # is absent on a source that has never finished one — say the elapsed alone
  # rather than guess a total.
  #
  # Only one source is ever executing. `CmsHarness.Project.AnalysisServer` runs
  # "one at a time" by design, because `mix test` and `mix spex` share
  # `_build/test` and two mix runs at once can corrupt the build. So among the
  # in-flight set the earliest-started is the one running and the rest are
  # waiting on it.
  #
  # That distinction is the whole of `0e4b35e8`. `started_at` is stamped at
  # enqueue, not at execution, so a queued source rendered as "credo, running
  # 20s of a typical 9s" — an analyzer at more than double its normal runtime,
  # which is the signature of a stuck process. Nothing was stuck: credo was
  # behind a 198-second spex sweep and took 8 seconds once it started. The
  # number was doing the opposite of its job, and it is most wrong exactly when
  # it matters most, because queue pressure is when stops block on stale sources
  # in the first place.
  #
  # Naming what it waits behind answers "should I wait?" in a way no duration
  # can. The executing source keeps its elapsed figure, which is what makes two
  # stops inside one window differ — a byte-identical block twice is the
  # livelock signature, and its advice is the opposite of this one's.
  defp running_detail(rerunning, run_duration, flight) do
    sorted = Enum.sort(rerunning)

    case executing(flight.sources, flight.since) do
      nil ->
        Enum.map_join(sorted, ", ", fn source ->
          source <> elapsed_clause(Map.get(flight.since, source), Map.get(run_duration, source))
        end)

      blocker ->
        waiting = sorted -- [blocker]
        progress = elapsed_clause(Map.get(flight.since, blocker), Map.get(run_duration, blocker))

        detail(blocker in sorted, blocker, progress, waiting)
    end
  end

  # The stale source is the one running: report it, and say what is behind it.
  defp detail(true, blocker, progress, waiting),
    do: blocker <> progress <> queued_clause(waiting)

  # The stale source is waiting on something that is not itself stale, so the
  # blocker never appeared in this sentence at all — which is how "queued" came
  # to read as "running". Naming it, with its progress, is what answers "should
  # I wait?": 60s into a typical 198s says roughly two minutes, and no duration
  # attached to the waiting source could say that.
  defp detail(false, blocker, progress, waiting),
    do:
      "#{Enum.join(waiting, ", ")} #{has(waiting)} not started — queued behind #{blocker}#{progress}"

  defp has([_one]), do: "has"
  defp has(_many), do: "have"

  defp queued_clause([]), do: ""

  defp queued_clause([one]), do: "; #{one} is queued behind it and has not started"

  defp queued_clause(many),
    do: "; #{Enum.join(many, ", ")} are queued behind it and have not started"

  # Nil when no in-flight source has a start time — a locally executed project
  # reports names alone, and inventing an order from nothing would name a
  # blocker that may not be one.
  defp executing(sources, since) do
    sources
    |> Enum.filter(&Map.has_key?(since, &1))
    |> Enum.min_by(&DateTime.to_unix(Map.fetch!(since, &1)), fn -> nil end)
  end

  defp elapsed_clause(%DateTime{} = started_at, typical) do
    elapsed = max(DateTime.diff(DateTime.utc_now(), started_at, :second), 0)

    case typical do
      seconds when is_integer(seconds) and seconds > 0 ->
        ", running #{duration_text(elapsed)} of a typical #{duration_text(seconds)}"

      _ ->
        ", running #{duration_text(elapsed)}"
    end
  end

  # Locally executed projects report which sources are running but not since
  # when, so there is nothing to say and the sentence stays as it was.
  defp elapsed_clause(_started_at, _typical), do: ""

  defp staleness_seconds(%DateTime{} = at), do: DateTime.diff(DateTime.utc_now(), at, :second)
  defp staleness_seconds(_), do: 0

  defp render_blocking_line(%Problem{} = problem, session_paths) do
    message =
      problem.message
      |> maybe_compact_message(true)
      |> truncate_message(@per_problem_cap)

    "  - #{format_location(problem)} — #{message}#{unedited_marker(problem, session_paths)}"
  end

  # Whose finding this is, when the answer is known.
  #
  # Several agents share one repo and rebase onto main, so a warning one pushes
  # blocks every other's stop in the same voice as their own work — and the
  # obvious repair on someone else's in-flight file can be actively wrong. One
  # case: deleting an unused `@endpoint` that a preview story overrides on
  # purpose, which silently falls back to the local endpoint that `~p` binds at
  # compile time.
  #
  # An empty set means no evidence rather than no edits: a session restart or a
  # path shape that did not normalize looks identical to a turn that wrote
  # nothing. Marking everything foreign on that reading would tell an agent to
  # ignore its own work, so absence of evidence stays silent.
  #
  # Marks only. Whether an unattributed finding should still block is a
  # question about what the gate is for, and getting it wrong switches the gate
  # off silently — not a decision to take from a message renderer.
  defp unedited_marker(%Problem{file_path: path}, %MapSet{} = session_paths)
       when is_binary(path) do
    cond do
      MapSet.size(session_paths) == 0 -> ""
      MapSet.member?(session_paths, path) -> ""
      true -> " (not edited by this session)"
    end
  end

  defp unedited_marker(_problem, _session_paths), do: ""

  # Say when nothing could be attributed, because the two states that produce no
  # demotion look identical from the response and lead opposite ways.
  #
  # `split_unattributed/2` used to refuse to demote on an empty path set as well
  # as a `nil` one, and this sentence was the compensation: the agent was handed
  # somebody else's finding in the same voice as its own, with no marker
  # (`unedited_marker/2` returns "" on an empty set, having nothing to compare
  # against), so the note told it to check `git log -1 -- <path>` itself.
  #
  # An empty set now demotes, so the note reports that instead of asking for the
  # work. It still says something, because silence would be wrong in the other
  # direction: an agent whose findings all became advisory should know why they
  # stopped blocking, and that the reason is a claim about *this session* rather
  # than a judgment that the findings do not matter. A gate that stops blocking
  # has to say so; that is the same rule the `unattributed_count` field follows.
  #
  # `76008385` is what the old shape cost: a QA agent, which writes no project
  # files by nature, followed this note exactly — `git log -1` per path,
  # confirmed neither was its own, escalated to the owner — and got the same
  # block again on the next stop, with no action available that would change it.
  #
  # Two claims in the old wording became false and are corrected here, both
  # reported as a single self-contradicting message (339725c7): findings with no
  # file, and spex findings, were named as still blocking while the same
  # paragraph announced a blanket demotion. Under story 894's rule an agent that
  # made no edits is blocked by nothing, spex and file-less findings included —
  # they block the next session that does edit.
  #
  # "No file this project tracks" rather than "no recorded edits", because the
  # session that reads this most often did record edits: a QA agent writing
  # under `.code_my_spec/qa/`, which git ignores, so nothing it wrote is a file
  # here (a9e9caca). Being told it had no recorded edits, having just written
  # its brief, reads as the gate being broken.
  defp attribution_note(%MapSet{} = session_paths, _internal?) do
    if MapSet.size(session_paths) == 0 do
      "\n\nThis session changed no file this project tracks, so every finding was " <>
        "demoted to advisory — an agent that made no edits is blocked by nothing. " <>
        "They are still real and still someone's: if one names a file you were " <>
        "about to work in, `git log -1 -- <path>` says whose, and telling its " <>
        "owner beats editing an in-flight file you do not own. The next session " <>
        "that does edit gets them."
    else
      ""
    end
  end

  # `nil` means project files changed while this task ran and nothing this
  # session recorded names a file the project has a record of. Blocking is the
  # intended answer — findings cannot be matched to a session, so none can be
  # demoted — and that part is unchanged.
  #
  # What this used to *say* was that the recording is broken, and invite a
  # framework issue. That is one cause and not the common one. The ordinary one
  # is a file created this turn: `verify_against_ledger/3` needs recorded paths
  # to join `File` rows, and a file the scanner has not reached yet has no row,
  # so a genuine edit to a genuine file lands here with a perfectly good ledger.
  #
  # Two agents filed that issue in one day (07bcd520, 6c27799f), both correct
  # that they had edited the file and both concluding sub-agent edits go
  # unrecorded — which is not the mechanism. They were reading the sentence
  # exactly as written, and following it cost them a report each and left the
  # real explanation, that the file is simply too new to have a row, unsaid.
  #
  # So it describes the state and orders the causes by how often they are it.
  # The invitation to report stays, narrowed to the case that is actually a
  # defect: paths that could never name a file here.
  defp attribution_note(_session_paths, _internal?) do
    "\n\nFiles in this project changed while this task ran, and nothing this " <>
      "session recorded names a file the project has a record of — so no finding " <>
      "could be attributed, none were demoted, and all of them block, including " <>
      "any that arrived with a rebase.\n\n" <>
      "The usual reason is a file created this turn: a file the scanner has not " <>
      "reached yet has no record to match against, and the next sync gives it " <>
      "one. If that is what happened, stopping again once the scan has run " <>
      "clears this by itself.\n\n" <>
      "Otherwise check `git log -1 -- <path>` before repairing anything you do " <>
      "not recognise. If the paths this session recorded could never name a file " <>
      "here — absolute paths, or another repository's — that is a real defect: " <>
      "`create_issue` with scope `framework`."
  end

  defp truncate_message(message, max) when is_binary(message) do
    if byte_size(message) <= max do
      message
    else
      Utf8.valid_prefix(message, max - 3) <> "..."
    end
  end

  defp truncate_message(message, _max), do: message

  defp render_advisory_section([], _unattributed), do: ""

  defp render_advisory_section(advisory, unattributed) do
    lines =
      advisory
      |> Enum.group_by(& &1.source)
      |> Enum.sort_by(fn {source, _} -> source end)
      |> Enum.map_join("\n", fn {source, items} ->
        "  - #{source}: #{length(items)} #{dominant_severity_label(items)} (advisory)"
      end)

    "\n\nAdditional problems (not blocking):\n" <> lines <> demoted_note(unattributed)
  end

  # Said out loud, because this is the gate having declined to block on
  # something. Folding them into the advisory counts unannounced would make
  # "the gate stopped blocking" and "there was nothing to block on" read the
  # same, which is the one confusion a demotion must not create.
  defp demoted_note(0), do: ""

  defp demoted_note(count) do
    "\n\n#{count} finding#{if count == 1, do: " is", else: "s are"} in files this " <>
      "session did not edit, so #{if count == 1, do: "it is", else: "they are"} " <>
      "advisory rather than blocking. If #{if count == 1, do: "it", else: "one"} " <>
      "is genuinely yours, the attribution is wrong — say so rather than working around it."
  end

  defp dominant_severity_label(items) do
    severity =
      items
      |> Enum.map(& &1.severity)
      |> Enum.frequencies()
      |> Enum.max_by(fn {_sev, count} -> count end)
      |> elem(0)
      |> Atom.to_string()

    case length(items) do
      1 -> severity
      _ -> "#{severity}s"
    end
  end

  defp enforce_total_cap(text, _blocking, _advisory) do
    truncate_to_cap(text)
  end

  @doc """
  Truncates a feedback string to fit within the agent context budget.

  Used by stop-hook responses, agent task prompts, and any other path
  that ships diagnostic text to the model — keeps a flood of problems
  from blowing the context window.

  ## Options

    * `:cap` — byte cap (default: `#{@total_response_cap}`).
    * `:footer` — text appended on truncation (default:
      `"\\n... more problems omitted (response size limit)"`).

  Truncation is newline-aware: when the text exceeds the cap the
  function trims at the last full newline that fits inside the budget
  (cap minus footer size) so we don't leave half a line dangling.
  """
  @spec truncate_to_cap(String.t(), keyword()) :: String.t()
  def truncate_to_cap(text, opts \\ []) when is_binary(text) do
    cap = Keyword.get(opts, :cap, @total_response_cap)
    footer = Keyword.get(opts, :footer, "\n... more problems omitted (response size limit)")

    if byte_size(text) <= cap do
      text
    else
      budget = cap - byte_size(footer)
      truncate_at_newline(text, budget) <> footer
    end
  end

  defp truncate_at_newline(text, budget) when byte_size(text) <= budget, do: text

  defp truncate_at_newline(text, budget) do
    chunk = Utf8.valid_prefix(text, budget)

    case :binary.matches(chunk, "\n") do
      [] ->
        chunk

      matches ->
        {pos, _} = List.last(matches)
        binary_part(chunk, 0, pos)
    end
  end

  # Private functions

  defp render_compact(%Problem{} = problem, opts) when is_list(opts) do
    include_source = Keyword.get(opts, :include_source, true)
    compact_message = Keyword.get(opts, :compact_message, false)
    max_length = Keyword.get(opts, :max_length)

    location = format_location(problem)
    severity = Atom.to_string(problem.severity)
    message = maybe_compact_message(problem.message, compact_message)

    base = "#{location}: [#{severity}] #{message}"

    rendered =
      case include_source do
        true -> "#{base} (#{problem.source})"
        false -> base
      end

    maybe_truncate(rendered, max_length)
  end

  # Back-compat: prior callers pass a bare boolean.
  defp render_compact(%Problem{} = problem, include_source) when is_boolean(include_source) do
    render_compact(problem, include_source: include_source)
  end

  defp maybe_compact_message(message, false), do: message

  defp maybe_compact_message(message, true) when is_binary(message) do
    message
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
  end

  defp maybe_compact_message(message, true), do: message

  defp maybe_truncate(text, nil), do: text

  defp maybe_truncate(text, max) when is_integer(max) and max > 3 do
    if byte_size(text) <= max do
      text
    else
      Utf8.valid_prefix(text, max - 3) <> "..."
    end
  end

  defp maybe_truncate(text, _), do: text

  defp render_text(%Problem{} = problem, include_source) do
    location = format_location(problem)
    severity = Atom.to_string(problem.severity)

    lines = [
      "Location: #{location}",
      "Severity: #{severity}",
      "Message: #{problem.message}"
    ]

    lines =
      case include_source do
        true -> lines ++ ["Source: #{problem.source}"]
        false -> lines
      end

    Enum.join(lines, "\n")
  end

  defp format_location(%Problem{file_path: file_path, line: nil}), do: file_path
  defp format_location(%Problem{file_path: file_path, line: line}), do: "#{file_path}:#{line}"

  defp sort_problems(problems) do
    Enum.sort_by(problems, fn problem ->
      severity_index = Enum.find_index(@severity_order, &(&1 == problem.severity)) || 99
      {severity_index, problem.file_path, problem.line || 0}
    end)
  end

  defp render_flat(problems, opts) do
    Enum.map_join(problems, "\n\n", &render(&1, opts))
  end

  defp render_grouped(problems, group_by, _opts) do
    problems
    |> Enum.group_by(&Map.get(&1, group_by))
    |> Enum.sort_by(fn {key, _} -> group_sort_key(group_by, key) end)
    |> Enum.map_join("\n\n", fn {key, group_problems} ->
      header = format_group_header(group_by, key)
      rendered = Enum.map_join(group_problems, "\n", &render_compact(&1, false))
      "## #{header}\n#{rendered}"
    end)
  end

  defp group_sort_key(:severity, key) do
    Enum.find_index(@severity_order, &(&1 == key)) || 99
  end

  defp group_sort_key(_group_by, key), do: key

  defp format_group_header(:severity, severity), do: "#{severity}s"
  defp format_group_header(:source, source), do: source
  defp format_group_header(:file_path, path), do: path

  defp count_by_severity(problems) do
    Enum.reduce(problems, %{}, fn problem, acc ->
      Map.update(acc, problem.severity, 1, &(&1 + 1))
    end)
  end

  defp render_severity_counts(problems) do
    counts = count_by_severity(problems)

    @severity_order
    |> Enum.map(fn severity -> {severity, Map.get(counts, severity, 0)} end)
    |> Enum.filter(fn {_severity, count} -> count > 0 end)
    |> Enum.map_join(", ", fn {severity, count} -> format_count(count, severity) end)
  end

  defp format_count(1, severity), do: "1 #{severity}"
  defp format_count(count, severity), do: "#{count} #{severity}s"
end
