defmodule Mix.Tasks.Cms.GraphObservations do
  @shortdoc "Prove every graph observation reached a recompute"

  @moduledoc """
  Reads a log set and reports whether every observation the requirement graph
  was told about was actually consumed by a recompute.

      mix cms.graph_observations
      mix cms.graph_observations --since 14:00 --logs ~/.codemyspec/web.log

  ## What it is for

  "The graph recomputes incrementally" was, until this existed, a claim checked
  by reading counts and believing them. The counts cannot support it. A line
  saying `recomputed 63 of 2078 requirements — 67 entity(ies) stale` is equally
  consistent with one observation, with twenty, and with an observation that
  arrived and was dropped on the floor — and a recompute that no observation
  asked for looks exactly like one that three did.

  Measured before this: of eight recomputes in half an hour, three could be
  tied to an issue by hand-comparing log timestamps against the database, and
  five had no identifiable cause. That is not a report anyone should have to
  produce twice.

  ## How the proof works

  Every writer that publishes a graph input mints an id
  (`GraphInputs.observation_id/0`) and logs it. `GraphWatcher` accumulates the
  ids it receives, and stamps them as `obs=` metadata on every line the
  recompute emits. So the chain is in the log:

      [FileSync] announcing a graph change ... obs=3f2a91c4
      [Requirements] recomputed 63 of 2078 ... obs=3f2a91c4,7b10de02

  An observation is *consumed* when its id appears in a later recompute. One
  that never does is an observation the graph was told about and did not act
  on, which is the failure this is built to catch.

  ## What it reports

    * consumed — announced, then named by a recompute. The good case.
    * dropped — announced and never named. A real defect.
    * pending — announced within the debounce window at the end of the range,
      so its recompute has not happened yet. Not a defect; excluded from the
      verdict rather than counted against it, because a report that cries wolf
      at its own boundary gets ignored.
    * unprompted — a recompute that named no observation (`obs=none`). Not
      necessarily wrong: a first read with nothing stored recomputes, and so
      does a reader arriving after a restart. Worth seeing, because a *stream*
      of them means something is invalidating the graph without announcing it.

  Exits non-zero when anything was dropped, so it can gate.
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
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [since: :string, logs: :keep, verbose: :boolean]
      )

    logs = opts |> Keyword.get_values(:logs) |> paths()
    lines = read_lines(logs)

    announced = announcements(lines, opts[:since])
    recomputes = recomputes(lines, opts[:since])

    named = recomputes |> Enum.flat_map(& &1.obs) |> MapSet.new()
    last_at = lines |> List.last() |> timestamp()

    {pending, settled} =
      Enum.split_with(announced, &within_grace?(&1.at, last_at))

    {consumed, dropped} = Enum.split_with(settled, &MapSet.member?(named, &1.id))
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

    if dropped != [], do: exit({:shutdown, 1})
  end

  defp paths([]), do: Enum.map(@default_logs, &Path.expand/1)
  defp paths(given), do: Enum.map(given, &Path.expand/1)

  defp read_lines(paths) do
    paths
    |> Enum.filter(&File.exists?/1)
    |> Enum.flat_map(&(&1 |> File.read!() |> String.split("\n")))
    |> Enum.filter(&String.starts_with?(&1, "ts="))
    |> Enum.sort()
  end

  # `announcing a graph change` is the one every publisher routes through, and
  # each carries the id it published.
  defp announcements(lines, since) do
    lines
    |> Enum.filter(&(String.contains?(&1, "announcing a graph change") and after?(&1, since)))
    |> Enum.flat_map(fn line ->
      case obs_ids(line) do
        [] -> []
        ids -> Enum.map(ids, &%{id: &1, at: timestamp(line), line: line})
      end
    end)
  end

  # Two kinds of line name an observation, and both must count.
  #
  # `[Requirements] recomputed` is the watcher's own pass doing the work. But
  # the architecture's normal case is a *reader* triggering the computation in
  # its own process, which carries no metadata — so the watcher also writes
  # `[GraphWatcher] accounted for`, saying which observations its pass answered
  # for whatever did the computing. Counting only the first reported an
  # observation as dropped that had in fact been applied nine seconds earlier.
  defp recomputes(lines, since) do
    lines
    |> Enum.filter(&(naming_line?(&1) and after?(&1, since)))
    |> Enum.map(&%{at: timestamp(&1), obs: obs_ids(&1), line: &1})
  end

  defp naming_line?(line) do
    String.contains?(line, "[Requirements] recomputed") or
      String.contains?(line, "[GraphWatcher] accounted for")
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
  defp after?(line, since), do: (timestamp(line) || "") >= since

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

    Graph observations — did every announcement reach a recompute?
    #{Enum.map_join(logs, "\n", &"  read #{&1}")}

      announced     #{length(announced)}
      recomputes    #{length(recomputes)}

      consumed      #{length(consumed)}
      dropped       #{length(dropped)}#{flag(dropped)}
      pending       #{length(pending)}  (inside the debounce window at the end of the range)
      unprompted    #{length(unprompted)}  (recomputes that named no observation)
    """)

    show("DROPPED — announced and never named by a recompute", dropped, verbose)
    show("PENDING — too recent to judge", pending, verbose)

    if verbose do
      show("UNPROMPTED — recomputed with obs=none", unprompted, true)
    end

    Mix.shell().info(verdict(dropped, announced))
  end

  defp flag([]), do: ""
  defp flag(_), do: "   <-- every one of these is an observation the graph ignored"

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

  defp verdict([], []), do: "  No observations in range — nothing to prove either way.\n"

  defp verdict([], _announced),
    do: "  PASS — every settled observation was named by a recompute.\n"

  defp verdict(dropped, _announced),
    do: "  FAIL — #{length(dropped)} observation(s) never reached a recompute.\n"
end
