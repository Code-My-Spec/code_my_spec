defmodule CodeMySpec.Problems.Tools do
  @moduledoc """
  Agent-facing problem operations and text rendering.

  This adapter reads Problems and Analysis without making the Problems core
  depend on the analysis service that writes its findings.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Analysis, CodeMySpec.Problems, CodeMySpec.Tools],
    exports: [ClearProblems, ListProblems]

  alias CodeMySpec.Analysis
  alias CodeMySpec.Problems

  @default_per_page 25
  @max_per_page 100

  def all, do: [__MODULE__.ClearProblems, __MODULE__.ListProblems]

  def rows(problems), do: Enum.map(problems, &row/1)

  def list_error(:missing_active_project), do: CodeMySpec.Tools.error(:missing_active_project)
  def list_error(reason), do: {:error, inspect(reason)}

  def clear(params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        case file_paths(params) do
          [] ->
            {:ok, count} = Problems.clear_project_problems(scope)
            {:ok, cleared_all_summary(count)}

          paths ->
            {:ok, _} = Problems.replace_problems_for_files(scope, paths, [])
            {:ok, cleared_files_summary(paths)}
        end

      {:error, reason} ->
        {:error, "Could not clear problems: #{reason}"}
    end
  end

  defp file_paths(params) do
    case Map.get(params, :file_paths) do
      list when is_list(list) -> Enum.reject(list, &(&1 in [nil, ""]))
      _ -> []
    end
  end

  defp cleared_all_summary(count),
    do:
      "Cleared #{count} persisted problem(s) for the project. Re-run validation to re-record any that are still real."

  defp cleared_files_summary(paths),
    do:
      "Cleared persisted problems for #{length(paths)} file(s): #{Enum.join(paths, ", ")}. " <>
        "Re-run validation to re-record any that are still real."

  def list(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, severity} <- severity(params) do
      opts = [
        page: page(params),
        per_page: per_page(params),
        filter: Map.get(params, :source) || :all,
        severity: severity
      ]

      %{problems: problems, total_count: total, page: page, total_pages: pages} =
        Problems.list_problems_paginated(scope, opts)

      {:ok, scope, problems, total, page, pages}
    end
  end

  defp row(problem) do
    %{
      "id" => problem.id,
      "severity" => to_string(problem.severity),
      "source" => problem.source,
      "file_path" => problem.file_path,
      "line" => problem.line,
      "message" => problem.message,
      "category" => problem.category,
      "rule" => problem.rule
    }
  end

  @severities ~w(error warning info)

  defp severity(params) do
    case Map.get(params, :severity) do
      nil ->
        {:ok, nil}

      value when value in @severities ->
        {:ok, String.to_existing_atom(value)}

      value ->
        {:error,
         "Unknown severity #{inspect(value)}. Expected one of: #{Enum.join(@severities, ", ")}."}
    end
  end

  defp page(params), do: max(Map.get(params, :page) || 1, 1)

  defp per_page(params) do
    (Map.get(params, :per_page) || @default_per_page)
    |> max(1)
    |> min(@max_per_page)
  end

  def render(_scope, [], total, _page, _pages, params) when total == 0 do
    case filters_in_play(params) do
      "" -> "No problems recorded for this working copy."
      filters -> "No problems#{filters} for this working copy. Call without them for all."
    end
  end

  def render(scope, problems, total, page, pages, params) do
    header =
      "# Problems (#{length(problems)} of #{total}) — page #{page}/#{max(pages, 1)}" <>
        severity_note(params)

    body = Enum.map_join(problems, "\n", &line/1)

    footer =
      if page < pages,
        do: "\n\nPage #{page + 1} of #{pages}: call again with `page: #{page + 1}`.",
        else: ""

    header <>
      "\n\n" <>
      body <>
      database_note(scope, problems) <>
      footer <>
      "\n\nRead retained stdout/stderr with `get_analysis_output({source = \"exunit\"})` " <>
      "(use the relevant analyzer source). Continue pages using its run_id and next_offset."
  end

  defp database_note(scope, problems) do
    problems
    |> Enum.map(& &1.source)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&partition_line(scope, &1))
    |> case do
      [] -> ""
      lines -> "\n\n" <> Enum.join(lines, "\n")
    end
  end

  defp partition_line(scope, source) do
    case Analysis.latest_answer(scope, source) do
      %{stats: %{"partition" => partition}} = run when is_binary(partition) ->
        ["#{source} ran against the `#{partition}` test database#{took(run)}."]

      %{} = run ->
        case took(run) do
          "" -> []
          taken -> ["#{source}'s run#{taken}."]
        end

      _ ->
        []
    end
  end

  defp took(%{started_at: %DateTime{} = started, finished_at: %DateTime{} = finished}) do
    case DateTime.diff(finished, started, :second) do
      seconds when seconds >= 120 -> ", and took #{div(seconds, 60)}m#{rem(seconds, 60)}s"
      _ -> ""
    end
  end

  defp took(_run), do: ""

  defp filters_in_play(params) do
    [
      {"severity", Map.get(params, :severity)},
      {"source", Map.get(params, :source)}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
    |> case do
      [] ->
        ""

      pairs ->
        " matching " <>
          Enum.map_join(pairs, " and ", fn {label, value} -> "#{label} #{value}" end)
    end
  end

  defp severity_note(params) do
    case Map.get(params, :severity) do
      nil -> ""
      severity -> " · severity: #{severity}"
    end
  end

  defp line(problem) do
    location =
      case problem.line do
        nil -> problem.file_path
        line -> "#{problem.file_path}:#{line}"
      end

    "- [#{problem.source}] #{location} — #{first_line(problem.message)}"
  end

  defp first_line(message) do
    message
    |> to_string()
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 160)
  end
end
