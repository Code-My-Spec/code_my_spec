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
    reproduce = Keyword.get(opts, :reproduce_commands, %{})
    session_paths = Keyword.get(opts, :session_paths)
    in_flight = Keyword.get(opts, :in_flight, [])

    header = "Fix these problems before stopping:\n\n"
    advisory_section = render_advisory_section(advisory)

    blocking_section =
      render_blocking_section(blocking, stale, last_ran, run_duration, reproduce, session_paths)

    raw =
      header <>
        blocking_section <>
        advisory_section <> stale_footer(blocking, stale, last_ran, run_duration, in_flight)

    enforce_total_cap(raw, blocking, advisory)
  end

  defp render_blocking_section(blocking, stale, last_ran, run_duration, reproduce, session_paths) do
    blocking
    |> Enum.group_by(& &1.source)
    |> Enum.sort_by(fn {source, _} -> source end)
    |> Enum.map_join(
      "\n",
      &render_blocking_group(&1, stale, last_ran, run_duration, reproduce, session_paths)
    )
  end

  defp render_blocking_group(
         {source, items},
         stale,
         last_ran,
         run_duration,
         reproduce,
         session_paths
       ) do
    count = length(items)
    visible = Enum.take(items, @per_source_list_cap)

    details = Enum.map_join(visible, "\n", &render_blocking_line(&1, session_paths))

    overflow =
      case count - length(visible) do
        0 -> ""
        n -> "\n  ... #{n} more #{source} problems (use get_issue to inspect)"
      end

    marker = stale_marker(source, stale, last_ran, run_duration)

    "#{source} (#{count})#{marker}:\n#{details}#{overflow}#{reproduce_line(source, reproduce)}"
  end

  # How to see these yourself. Only where the gate's command and the obvious
  # one disagree — credo, whose plain invocation hides the low-priority band
  # these are promoted from — so this stays a fact worth reading rather than
  # noise appended to every group.
  defp reproduce_line(source, reproduce) do
    case Map.get(reproduce, source) do
      command when is_binary(command) and command != "" -> "\n  reproduce: #{command}"
      _ -> ""
    end
  end

  # Marked, not dropped: dropping opens an escape at the last stop of a run
  # and hides an analyzer that fails every time.
  #
  # With an age, because "stale" alone does not say whether waiting will help.
  # A source that last ran two minutes ago is mid-cycle; one that last ran
  # forty minutes ago has not been coming back, and the right response is to
  # report the analyzer rather than stop again. Those need opposite actions and
  # the message could not tell them apart.
  defp stale_marker(source, stale, last_ran, run_duration) do
    case {MapSet.member?(stale, source), Map.get(last_ran, source)} do
      {false, _} ->
        ""

      {true, %DateTime{} = at} ->
        " — stale, last ran #{ago(at)}#{run_window(source, at, run_duration)}"

      {true, _} ->
        " — stale, has never completed"
    end
  end

  # Only when the run is slower than the age, which is the case the age alone
  # renders absurd: "stale, last ran 0s ago" on a run that had just succeeded.
  # It had not gone stale since finishing — the edit landed while it ran.
  defp run_window(source, at, run_duration) do
    if overtaken?(source, at, run_duration),
      do: " (run takes #{duration_text(Map.get(run_duration, source))})",
      else: ""
  end

  # The result was already answering about an older tree when it arrived.
  #
  # A run is fingerprinted at enqueue and judged against the tree when read, so
  # an edit inside its window makes it stale on completion. Comparing the age to
  # the duration is what separates that from an ordinary lag, and they take
  # opposite advice: one is fixed by waiting and one cannot be.
  defp overtaken?(source, %DateTime{} = at, run_duration) do
    case Map.get(run_duration, source) do
      seconds when is_integer(seconds) and seconds > 0 -> staleness_seconds(at) < seconds
      _ -> false
    end
  end

  defp overtaken?(_source, _at, _run_duration), do: false

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

  defp stale_footer(blocking, stale, last_ran, run_duration, in_flight) do
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
          escalation(sources, last_ran, run_duration, in_flight)
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
  defp escalation(sources, last_ran, run_duration, in_flight) do
    age =
      sources
      |> Enum.map(&Map.get(last_ran, &1))
      |> Enum.map(&staleness_seconds/1)
      |> Enum.max(fn -> 0 end)

    rerunning = Enum.filter(sources, &(&1 in in_flight))
    overtaken = Enum.filter(sources, &overtaken?(&1, Map.get(last_ran, &1), run_duration))

    # Checked before the others because it is the most specific condition and
    # the only one none of them describes. "A rerun is in flight, stop again"
    # and "stopping again enqueues one" are both advice to wait, and waiting is
    # what cannot work here — the next edit overtakes the rerun exactly as it
    # overtook this one.
    if overtaken != [] do
      overtaken_sentence(overtaken, run_duration, rerunning)
    else
      wait_or_report(age, rerunning)
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

  defp wait_or_report(age, rerunning) do
    case {age, rerunning} do
      {_age, [_ | _] = running} ->
        " A rerun is in flight now (#{Enum.join(Enum.sort(running), ", ")}) — stop " <>
          "again and let it replace these."

      {age, []} when age > 900 ->
        " The newest of these results is #{div(age, 60)} minutes old and no rerun " <>
          "is running, so nothing is going to replace it on its own: treat the " <>
          "analyzer as failing and report it rather than editing around it."

      {_age, []} ->
        " No rerun is in flight. Stopping again enqueues one; if these persist " <>
          "across several stops with no change, the analyzer itself is failing — " <>
          "report that rather than editing around it."
    end
  end

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
