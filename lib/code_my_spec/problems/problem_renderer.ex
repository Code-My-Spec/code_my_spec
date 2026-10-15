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
  # Pinned by acceptance criteria; changing it is a product decision, not a
  # renderer one.
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

    if include_summary, do: render_summary(problems) <> "\n\n" <> rendered, else: rendered
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
      if truncated_count > 0,
        do:
          parts ++
            ["", "(#{truncated_count} more — `list_problems` has them, filter with `source`)"],
        else: parts

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
    enumerated; overflow surfaces as `... N more <source> problems` with a
    `list_problems` call to page through them.
  - Advisory problems are never enumerated — they collapse to one
    summary line per source: `- <source>: N <severity>s (advisory)`.
  - The total response is capped at `@total_response_cap` bytes; excess
    is truncated with `... more problems omitted (response size limit)`.

  Returns `""` when there are no blocking problems — the allow path
  never produces a stop reason.
  """
  @spec render_stop_response([Problem.t()], [Problem.t()], keyword()) :: String.t()
  def render_stop_response(blocking, advisory, opts \\ [])

  def render_stop_response([], _advisory, _opts), do: ""

  def render_stop_response(blocking, advisory, opts) do
    reproduce = Keyword.get(opts, :reproduce_commands, %{})
    session_paths = Keyword.get(opts, :session_paths)

    # An in-app agent has no session and owns its whole checkout. Threaded to
    # `attribution_note/2`, which does not currently vary on it.
    internal? = Keyword.get(opts, :internal_agent?, false)
    header = "Fix these problems before stopping:\n\n"

    advisory_section = render_advisory_section(advisory)

    runs = %{
      answers: Keyword.get(opts, :answers, %{}),
      failures: Keyword.get(opts, :run_failures, %{}),
      analyzer_staleness: Keyword.get(opts, :analyzer_staleness, %{}),
      failed_reruns: Keyword.get(opts, :failed_reruns, %{})
    }

    attribution = %{
      session_paths: session_paths,
      latched: opts |> Keyword.get(:specs_ready_stamp, %{}) |> Map.keys() |> MapSet.new()
    }

    blocking_section = render_blocking_section(blocking, runs, reproduce, attribution)

    raw =
      header <>
        blocking_section <>
        advisory_section <>
        assignment_note(blocking, advisory, Keyword.get(opts, :story_assignment, %{})) <>
        specs_ready_note(blocking, Keyword.get(opts, :specs_ready_stamp, %{})) <>
        attribution_note(session_paths, internal?)

    enforce_total_cap(raw, blocking, advisory)
  end

  @doc """
  What an allowed stop says about findings that are not blocking it.

  A working copy surfaces every finding about it regardless of assignment. This
  names advisory findings on stories assigned elsewhere or to no checkout, one
  line each. Findings on this checkout's own stories are left out, and a project
  with no assignments sees none of this. `nil` when there is nothing to say.
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

  # Whose stories these findings are on, blocking and advisory alike.
  # Orientation only: it never changes what blocks.
  # See knowledge/analysis, "Stop response".
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

  # When and on what commit a blocking spex finding's project-wide
  # specs_ready latch was earned, so a checkout without the fix can check its
  # HEAD before assuming it broke it. Orientation only.
  defp specs_ready_note(_blocking, stamps) when map_size(stamps) == 0, do: ""

  defp specs_ready_note(blocking, stamps) do
    blocking
    |> Enum.filter(&(&1.source == "spex" and is_binary(&1.file_path)))
    |> Enum.map(& &1.file_path)
    |> Enum.uniq()
    |> Enum.flat_map(fn path ->
      case Map.get(stamps, path) do
        %{at: at, commit: commit} when not is_nil(at) or not is_nil(commit) ->
          ["  - #{path} — #{stamp_text(at, commit)}"]

        _ ->
          []
      end
    end)
    |> Enum.take(@per_source_list_cap)
    |> case do
      [] ->
        ""

      lines ->
        "\n\nspecs_ready was earned at:\n" <>
          Enum.join(lines, "\n") <>
          "\n\nIf you don't recognize this as your own change, check whether your " <>
          "checkout already has the commit named above before assuming you " <>
          "introduced it — specs_ready is set once, project-wide, and every " <>
          "checkout is held to it whether or not it has the fix yet."
    end
  end

  defp stamp_text(nil, nil), do: "no record of when or on what commit"

  defp stamp_text(at, commit) do
    [time_phrase(at), commit_phrase(commit)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp time_phrase(nil), do: nil
  defp time_phrase(at), do: "#{DateTime.to_iso8601(at)}"

  defp commit_phrase(nil), do: nil
  defp commit_phrase(commit), do: "commit #{String.slice(commit, 0, 8)}"

  # `runs` is what the ledger says about each source (answering run, failures,
  # analyzer staleness, failed reruns). `attribution` is the paths this session
  # wrote and the paths on a latched story (`specs_ready_stamp`'s keys).
  defp render_blocking_section(blocking, runs, reproduce, attribution) do
    blocking
    |> Enum.group_by(& &1.source)
    |> Enum.sort_by(fn {source, _} -> source end)
    |> Enum.map_join("\n", &render_blocking_group(&1, runs, reproduce, attribution))
  end

  defp render_blocking_group({source, items}, runs, reproduce, attribution) do
    %{session_paths: session_paths, latched: latched} = attribution
    count = length(items)
    visible = Enum.take(items, @per_source_list_cap)

    details = Enum.map_join(visible, "\n", &render_blocking_line(&1, session_paths))

    overflow =
      case count - length(visible) do
        0 ->
          ""

        n ->
          "\n  ... #{n} more #{source} problems — `list_problems({source = \"#{source}\"})` " <>
            "has them, page through with `page` and `per_page`"
      end

    marker = run_marker(source, runs)

    "#{source} (#{count})#{marker}:\n#{details}#{overflow}" <>
      reproduce_line(source, reproduce) <>
      killed_note(items) <>
      foreign_spex_note(source, items, session_paths, latched) <>
      precondition_note(items) <>
      stale_build_note(source, runs) <>
      failed_rerun_note(source, runs)
  end

  # A harness runs the analyzer it booted with, so a rerun repeats old code
  # until it is rebuilt. Per source: one analyzer can be behind while another
  # is current.
  defp stale_build_note(source, %{analyzer_staleness: notes}) do
    case Map.get(notes, source) do
      note when is_binary(note) -> "\n  Analyzer build: #{note}."
      _ -> ""
    end
  end

  defp stale_build_note(_source, _runs), do: ""

  # The newest run failed behind an older answer, so these findings were not re-checked.
  defp failed_rerun_note(source, %{failed_reruns: reruns}) do
    case Map.get(reruns, source) do
      %{failed_at: failed_at, answered_at: answered_at} = rerun ->
        reason = if rerun[:reason], do: ": #{rerun.reason}", else: ""

        "\n  Latest #{source} run failed at #{time_phrase(failed_at)}#{reason}." <>
          "\n  These findings are from the run at #{time_phrase(answered_at)} and were not re-checked."

      _ ->
        ""
    end
  end

  defp failed_rerun_note(_source, _runs), do: ""

  # Why a spex still blocks in a file this session did not touch: spex is exempt
  # from attribution demotion (`@attribution_exempt_sources`). Only for a
  # foreign finding on a latched story; an orphan never earned a latch.
  # See knowledge/analysis, "Stop response".
  defp foreign_spex_note("spex", items, %MapSet{} = session_paths, latched) do
    foreign? =
      MapSet.size(session_paths) > 0 and
        Enum.any?(items, fn
          %Problem{file_path: path} when is_binary(path) ->
            MapSet.member?(latched, path) and not MapSet.member?(session_paths, path)

          _ ->
            false
        end)

    if foreign? do
      "\n  A red spex blocks even in a file this session did not touch — spex is " <>
        "the one source attribution does not demote. That is because the latch " <>
        "making it blocking is earned, not asserted: `specs_ready` is set by a " <>
        "green spex run and cleared when the story is released or parked. So " <>
        "these went green once, and something has changed since. Usually that is " <>
        "a regression in this working copy; it can also be a precondition this " <>
        "checkout does not have — see any note below. Fix it, or if the story is " <>
        "genuinely mid-rework, park it — changing `ready_for_dev` clears the " <>
        "latch and these stop blocking."
    else
      ""
    end
  end

  defp foreign_spex_note(_source, _items, _session_paths, _latched), do: ""

  # A group whose every finding is `** (EXIT …) killed` reports on the machine,
  # not the code. All rather than any: one kill beside real failures is a run
  # that mostly worked.
  # See knowledge/analysis, "Stop response".
  defp killed_note([]), do: ""

  defp killed_note(items) do
    if Enum.all?(items, &killed?/1) do
      "\n  (#{killed_subject(length(items))} the machine, not the code: check load " <>
        "and concurrent runs, and clear these rather than editing anything.)"
    else
      ""
    end
  end

  # Singular wording for one, rather than "all 1 are".
  defp killed_subject(1),
    do:
      "this is a killed process, not an assertion — the suite was terminated rather than failing. That is"

  defp killed_subject(n),
    do:
      "all #{n} are killed processes, not assertions — the suite was terminated rather than failing. That is"

  defp killed?(%Problem{message: message}) when is_binary(message),
    do: message =~ ~r/\*\* \(EXIT from #PID<[^>]+>\) killed/

  defp killed?(_problem), do: false

  # A criterion that never reached its assertions (a missing local
  # precondition, e.g. the gitignored fleet key) has not regressed. Counted per
  # finding, unlike `killed_note/1`, because each one is identifiable.
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

  # How to see these yourself, only where the gate's command and the obvious one
  # disagree (plain `mix credo` hides the low-priority band these are promoted
  # from). `{command, why}` also says why the obvious command was wrong.
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

  # Which run recorded these findings: its commit and age. No "stale" label:
  # findings from the latest completed run always block, and a label sent agents
  # to wait out reruns instead of reading the finding.
  defp run_marker(source, %{answers: answers, failures: failures}) do
    case Map.get(answers, source) do
      %{} = answer ->
        " — from the run#{at_commit(answer[:commit])}#{finished(answer[:finished_at])}"

      nil ->
        " — has never completed a run" <> failure_clause(Map.get(failures, source))
    end
  end

  defp at_commit(commit) when is_binary(commit), do: " at #{String.slice(commit, 0, 8)}"
  defp at_commit(_commit), do: ""

  defp finished(%DateTime{} = at), do: ", finished #{ago(at)}"
  defp finished(_at), do: ""

  # Why it never completed, in the analyzer's own words (`Run.output`, written by
  # `Reconciler.fail/2`). Indented so foreign output never reads as our prose.
  defp failure_clause(nil), do: ""

  defp failure_clause(reason) do
    body = reason |> String.split("\n") |> Enum.map_join("\n", &("      " <> &1))
    "\n\n    The analyzer could not run. It said:\n\n" <> body <> "\n"
  end

  defp ago(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      s when s < 90 -> "#{s}s ago"
      s when s < 5400 -> "#{div(s, 60)}m ago"
      s -> "#{div(s, 3600)}h ago"
    end
  end

  defp render_blocking_line(%Problem{} = problem, session_paths) do
    message =
      problem.message
      |> maybe_compact_message(true)
      |> truncate_message(@per_problem_cap)

    "  - #{format_location(problem)} — #{message}#{unedited_marker(problem, session_paths)}"
  end

  # Marks a finding in a file this session did not edit. An empty set is no
  # evidence, so it marks nothing. Marks only: blocking is `Validation`'s call.
  defp unedited_marker(%Problem{file_path: path}, %MapSet{} = session_paths)
       when is_binary(path) do
    cond do
      MapSet.size(session_paths) == 0 -> ""
      MapSet.member?(session_paths, path) -> ""
      true -> " (not edited by this session)"
    end
  end

  defp unedited_marker(_problem, _session_paths), do: ""

  # An empty path set: none of these came from this session's edits, and they
  # block anyway — a stop judges the whole copy. "No file this project tracks"
  # because a QA agent writes only gitignored files and did record edits.
  defp attribution_note(%MapSet{} = session_paths, _internal?) do
    if MapSet.size(session_paths) == 0 do
      "\n\nThis session changed no file this project tracks, so none of these " <>
        "came from its edits. They block anyway: a stop judges the whole working " <>
        "copy. If one names a file you were about to work in, `git log -1 -- <path>` " <>
        "says whose, and telling its owner beats editing an in-flight file you do " <>
        "not own."
    else
      ""
    end
  end

  # `nil`: files changed but nothing recorded names a tracked file, so no finding
  # can be marked as this session's or not. The usual cause is a file too new to
  # have a `File` row (`verify_against_ledger/3` joins on them); a framework
  # issue only for paths that could never name a file here.
  defp attribution_note(_session_paths, _internal?) do
    "\n\nFiles in this project changed while this task ran, and nothing this " <>
      "session recorded names a file the project has a record of — so no finding " <>
      "can be marked as this session's or someone else's. All of them block, " <>
      "including any that arrived with a rebase.\n\n" <>
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

  defp render_advisory_section([]), do: ""

  defp render_advisory_section(advisory) do
    lines =
      advisory
      |> Enum.group_by(& &1.source)
      |> Enum.sort_by(fn {source, _} -> source end)
      |> Enum.map_join("\n", fn {source, items} ->
        "  - #{source}: #{length(items)} #{dominant_severity_label(items)} (advisory)"
      end)

    "\n\nAdditional problems (not blocking):\n" <> lines
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
      if include_source, do: "#{base} (#{problem.source})", else: base

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
      if include_source, do: lines ++ ["Source: #{problem.source}"], else: lines

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
