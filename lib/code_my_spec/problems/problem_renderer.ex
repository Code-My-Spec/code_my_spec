defmodule CodeMySpec.Problems.ProblemRenderer do
  @moduledoc """
  Utility module for rendering Problem structs into human and AI-readable formats.
  Transforms normalized problems from static analysis tools, compilers, and test
  failures into actionable feedback strings for Claude Code agent evaluation hooks.
  """

  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Utils.Utf8

  @severity_order [:error, :warning, :info]

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
