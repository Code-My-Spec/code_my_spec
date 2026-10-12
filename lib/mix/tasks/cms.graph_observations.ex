defmodule Mix.Tasks.Cms.GraphObservations do
  @shortdoc "Verify that graph observations have completion evidence"

  @moduledoc """
  Checks that every announced observation has a subsequent completion record.

      mix cms.graph_observations --logs ~/.codemyspec/web.log
      mix cms.graph_observations --since 14:00 --logs ~/.codemyspec/web.log

  Accepts completion records from GraphWatcher and ShadowProjector. A raw
  recompute log is not proof of completion: a later checkout or queue write
  can still fail. Overlapping log files are deduplicated.

  Unanswered observations within 30 seconds of the log range's end are pending;
  older ones are unaccounted for. Neither is a passing verification result.
  Missing files, unnamed announcements, invalid arguments, and an empty range
  also fail. A successful exit requires every announcement to be accounted for.

  Time-only filters apply to the time of day on every date in the log set;
  use a full local ISO timestamp to select a particular day. This command
  judges a captured range, not whether a live log has stopped progressing.

  This proves log accounting, not graph correctness. Use cms.graph_verify to
  compare served requirements and offered work with a fresh computation.
  """

  use Boundary, classify_to: CodeMySpec
  use Mix.Task

  @default_logs ["~/.codemyspec/web.log"]

  # One debounce window (2s) plus room for the recompute itself. An observation
  # announced inside this of the last line in the range has not had its chance
  # yet, and calling it dropped would be the report being wrong on purpose.
  @pending_grace_ms 30_000

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [since: :string, logs: :keep, verbose: :boolean]
      )

    if args != [] or invalid != [], do: Mix.raise("Invalid graph observation arguments")
    validate_since!(opts[:since])

    logs = opts |> Keyword.get_values(:logs) |> paths()
    lines = read_lines(logs)

    announced = announcements(lines, opts[:since])
    recomputes = recomputes(lines, opts[:since])

    last_at = lines |> List.last() |> timestamp()

    completed_at =
      Enum.reduce(recomputes, %{}, fn completed, times ->
        Enum.reduce(completed.obs, times, fn id, acc ->
          Map.update(acc, id, completed.at, &max(&1, completed.at))
        end)
      end)

    {consumed, unanswered} =
      Enum.split_with(announced, fn announcement ->
        case Map.fetch(completed_at, announcement.id) do
          {:ok, at} -> at >= announcement.at
          :error -> false
        end
      end)

    {pending, dropped} = Enum.split_with(unanswered, &within_grace?(&1.at, last_at))
    unprompted = Enum.filter(recomputes, &(&1.obs == []))

    report(
      logs,
      announced,
      recomputes,
      consumed,
      dropped,
      pending,
      unprompted,
      opts[:verbose] == true
    )

    if dropped != [] or pending != [] or announced == [], do: exit({:shutdown, 1})
  end

  defp paths([]), do: Enum.map(@default_logs, &Path.expand/1)
  defp paths(given), do: Enum.map(given, &Path.expand/1)

  defp read_lines(paths) do
    paths
    |> Enum.flat_map(&(&1 |> File.read!() |> String.split("\n")))
    |> Enum.filter(&String.starts_with?(&1, "ts="))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # `announcing a graph change` is the one every publisher routes through, and
  # each carries the id it published.
  defp announcements(lines, since) do
    lines
    |> Enum.filter(&(String.contains?(&1, "announcing a graph change") and after?(&1, since)))
    |> Enum.flat_map(fn line ->
      case obs_ids(line) do
        [] -> Mix.raise("An announcement has no observation ID; evidence is incomplete")
        ids -> Enum.map(ids, &%{id: &1, at: timestamp(line), line: line})
      end
    end)
  end

  # Completion is recorded only after all work for the drain succeeds.
  defp recomputes(lines, since) do
    lines
    |> Enum.filter(&(naming_line?(&1) and after?(&1, since)))
    |> Enum.map(&%{at: timestamp(&1), obs: obs_ids(&1), line: &1})
  end

  defp naming_line?(line) do
    String.contains?(line, "[GraphWatcher] accounted for") or
      String.contains?(line, "[ShadowProjector] accounted for")
  end

  # `obs=none` is a recompute that named nothing, which is a real answer rather
  # than a missing field, so it maps to the empty list.
  defp obs_ids(line) do
    case Regex.run(~r/\bobs=([a-z0-9,]+)/, line) do
      [_, "none"] -> []
      [_, ids] -> ids |> String.split(",") |> Enum.reject(&(&1 in ["", "unnamed"]))
      _ -> []
    end
  end

  defp timestamp(nil), do: nil

  defp timestamp(line) do
    case Regex.run(~r/^ts=([0-9T:.\-]+)/, line) do
      [_, ts] -> ts
      _ -> nil
    end
  end

  defp after?(_line, nil), do: true

  defp after?(line, since) when byte_size(since) in [5, 8],
    do: String.slice(timestamp(line) || "", 11, byte_size(since)) >= since

  defp after?(line, since), do: (timestamp(line) || "") >= since

  defp validate_since!(nil), do: :ok

  defp validate_since!(since) do
    value = if byte_size(since) == 5, do: since <> ":00", else: since

    valid? =
      if byte_size(since) in [5, 8],
        do: match?({:ok, _}, Time.from_iso8601(value)),
        else: match?({:ok, _}, NaiveDateTime.from_iso8601(value))

    unless valid?, do: Mix.raise("--since must be HH:MM, HH:MM:SS, or an ISO local timestamp")
  end

  defp within_grace?(_at, nil), do: false

  defp within_grace?(at, last_at) do
    with {:ok, a} <- NaiveDateTime.from_iso8601(at),
         {:ok, b} <- NaiveDateTime.from_iso8601(last_at) do
      NaiveDateTime.diff(b, a, :millisecond) < @pending_grace_ms
    else
      _ -> false
    end
  end

  defp report(logs, announced, recomputes, consumed, dropped, pending, unprompted, verbose) do
    Mix.shell().info("""

    Graph observations — did every announcement reach completion?
    #{Enum.map_join(logs, "\n", &"  read #{&1}")}

      announced     #{length(announced)}
      completions   #{length(recomputes)}

      consumed      #{length(consumed)}
      dropped       #{length(dropped)}#{flag(dropped)}
      pending       #{length(pending)}  (inside the debounce window at the end of the range)
      unprompted    #{length(unprompted)}  (completions that named no observation)
    """)

    show("UNACCOUNTED FOR — announced, never named by any completion", dropped, verbose)

    if dropped != [] do
      Mix.shell().info("""
        Either the graph never acted on these, or something acted on them that
        could not name them. Both look identical here, which is the point: an
        observation nothing accounts for cannot be shown to have been applied.
      """)
    end

    show("PENDING — too recent to judge", pending, verbose)

    if verbose do
      show("UNPROMPTED — recomputed with obs=none", unprompted, true)
    end

    Mix.shell().info(verdict(dropped, announced, pending))
  end

  defp flag([]), do: ""

  # "Ignored" is a stronger claim than the evidence supports, and overstating
  # it is how a report gets discounted. An unnamed observation may have been
  # applied by a reader-driven recompute that could not name it — measured, on
  # the run that produced this comment — so the honest word is unaccounted-for,
  # with the two candidate causes said out loud.
  defp flag(_), do: "   <-- announced and never accounted for"

  defp show(_title, [], _verbose), do: :ok

  defp show(title, rows, verbose) do
    Mix.shell().info("  " <> title)

    rows
    |> then(fn r -> if verbose, do: r, else: Enum.take(r, 10) end)
    |> Enum.each(fn row ->
      Mix.shell().info("    #{row.at}  #{Map.get(row, :id, "")}")
    end)

    if not verbose and length(rows) > 10 do
      Mix.shell().info("    … #{length(rows) - 10} more (--verbose)")
    end

    Mix.shell().info("")
  end

  defp verdict([], [], _pending),
    do: "  No observations in range — nothing to prove either way.\n"

  defp verdict([], _announced, []),
    do: "  PASS — every settled observation was named by a completion.\n"

  defp verdict([], _announced, _pending),
    do: "  INCOMPLETE — observations are still pending; agreement is not established.\n"

  defp verdict(dropped, _announced, _pending),
    do: "  FAIL — #{length(dropped)} observation(s) unaccounted for.\n"
end
