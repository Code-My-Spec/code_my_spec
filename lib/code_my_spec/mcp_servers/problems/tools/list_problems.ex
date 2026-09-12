defmodule CodeMySpec.McpServers.Problems.Tools.ListProblems do
  @moduledoc """
  The findings behind the alert, for the agent that wants them.

  `Hooks.AnalysisAlert` puts a count and an age on every tool call and stops
  there — a finding list on every call is noise the model learns to skip, which
  costs the signal a second time and more permanently than never sending it. So
  the alert pushes the fact and this pulls the detail, and the split only works
  because asking is one tool call.

  ## Paginated, and not optionally

  This working copy holds over 400 credo findings. An unpaginated list would
  overflow the tool-response window for the same reason the alert is counts-only
  — and a tool that dies on a large project is one nobody can rely on when a
  project gets large, which is exactly when they need it.

  Defaults to the first page and to `error` severity, because the common case is
  "what is blocking me" rather than "everything anyone has ever noticed".

  Scoped to the working copy, like everything else keyed on the harness: these
  are the findings from *this* checkout's analyzers, not the project's.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Analysis
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Problems

  @default_per_page 25
  @max_per_page 100

  schema do
    field :source, :string,
      doc:
        "Filter to one analyzer — `compiler`, `credo`, `exunit`, `spex`, `spec_validation` or `qa_validation`."

    field :severity, :string,
      doc: "Filter by severity — `error`, `warning` or `info`. Omit for all."

    field :page, :integer, doc: "1-based page number. Default: 1."

    field :per_page, :integer,
      doc: "Findings per page. Default: #{@default_per_page}, max #{@max_per_page}."
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame, params) do
      {:ok, scope} ->
        case severity(params) do
          {:ok, severity} ->
            opts = [
              page: page(params),
              per_page: per_page(params),
              filter: Map.get(params, :source) || :all,
              severity: severity
            ]

            %{problems: problems, total_count: total, page: page, total_pages: pages} =
              Problems.list_problems_paginated(scope, opts)

            {:reply, ok(render(scope, problems, total, page, pages, params)), frame}

          {:error, reason} ->
            {:reply, error(reason), frame}
        end

      {:error, reason} ->
        {:reply, error(reason), frame}
    end
  end

  # `severity` was declared in the schema, printed in the header as
  # "· severity: error", and never applied — so the tool labelled an unfiltered
  # list as filtered, which is worse than ignoring the parameter. Two agents
  # called it while trying to check a stop-hook refusal against the record and
  # got an answer to a question they had not asked (2071faa6, 339725c7).
  #
  # Rejected rather than ignored when unrecognised, for the same reason: a
  # filter that quietly does nothing is indistinguishable from one that matched
  # nothing.
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

  # Names the filters in play. "No problems recorded" under a severity or source
  # filter reads as "this working copy is clean", and an agent checking a
  # refusal against the record will believe the refusal is phantom.
  defp render(_scope, [], total, _page, _pages, params) when total == 0 do
    case filters_in_play(params) do
      "" -> "No problems recorded for this working copy."
      filters -> "No problems#{filters} for this working copy. Call without them for all."
    end
  end

  defp render(scope, problems, total, page, pages, params) do
    header =
      "# Problems (#{length(problems)} of #{total}) — page #{page}/#{max(pages, 1)}" <>
        severity_note(params)

    body = Enum.map_join(problems, "\n", &line/1)

    # Says how to get the rest rather than leaving the reader to guess the
    # parameter — a truncated list that does not say it is truncated reads as a
    # complete one, which is the failure this whole story is about.
    footer =
      if page < pages,
        do: "\n\nPage #{page + 1} of #{pages}: call again with `page: #{page + 1}`.",
        else: ""

    header <> "\n\n" <> body <> database_note(scope, problems) <> footer
  end

  # Which database produced these, for the sources that opened one.
  #
  # A working copy has three test databases and a run uses exactly one, and this
  # list never said which. Both times it mattered, every other signal pointed at
  # the code: 479 spex failures naming a column the tree actually had, against a
  # partition five days behind the base (`d86b09cd`); and a criterion passing in
  # isolation while failing every sweep, because a foreign key was `CASCADE` on
  # one database and `RESTRICT` on the other. The second cost three promotion
  # refusals before anybody thought to ask which database had answered.
  #
  # One line, and the reader's next question becomes "why is *that* one
  # answering" rather than "what is wrong with my code".
  #
  # Only the sources actually on this page, and only those carrying a partition
  # — the compiler and credo read files rather than opening a connection, and a
  # run recorded before this shipped has nothing to say. Saying nothing is
  # correct for all three; inventing a database name would be the failure this
  # exists to end, one level up.
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
      %{stats: %{"partition" => partition}} when is_binary(partition) ->
        ["#{source} ran against the `#{partition}` test database."]

      _ ->
        []
    end
  end

  defp filters_in_play(params) do
    [
      {"severity", Map.get(params, :severity)},
      {"source", Map.get(params, :source)}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
    |> case do
      [] -> ""
      pairs -> " matching " <> Enum.map_join(pairs, " and ", fn {l, v} -> "#{l} #{v}" end)
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

  # One line per finding. A credo message runs to a paragraph and 25 of those is
  # the window this tool exists to stay inside.
  defp first_line(message) do
    message
    |> to_string()
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 160)
  end

  defp ok(text), do: Response.tool() |> Response.text(text)
  defp error(reason), do: Response.tool() |> Response.error(inspect(reason))
end
