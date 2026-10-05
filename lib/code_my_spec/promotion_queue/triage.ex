defmodule CodeMySpec.PromotionQueue.Triage do
  @moduledoc """
  What a red batch does next, decided from its findings alone.

  In order, cheapest first:

    0. **Main's own red is not the batch's.** A failing test is re-run in the
       gate copy at main's commit, then at the batch commit (`baseline_files/1`);
       a finding red at main too is excluded and the batch gated again without it.
       The re-run at the batch commit is also the one re-run a flake gets.
    1. **A lone failure is re-run once.** One blocking finding from one analyzer
       is the shape a flaky test takes, and ejecting a candidate over a flake
       sends an agent to fix code that is not broken.
    2. **Attribute before bisecting.** When every finding sits in a file only
       one candidate changed, that candidate is the culprit and the rest are
       re-gated without it — no bisect needed.
    3. **Otherwise bisect.** Gate the first half; a green half lands, a red one
       is split again, and a red batch of one is ejected.
  """

  @type problem :: %{required(:source) => String.t(), required(:file_path) => String.t() | nil}

  @baseline_sources ~w(exunit spex)

  @doc """
  The files to re-run at main's commit, by source, to tell whether a red
  batch's findings are main's own.

  Tests only: a test file can be run on its own, and a test is what
  goes red on main without anyone's candidate — a flake, or a latched spex
  whose implementation has not landed (story 1060, 2026-10-05). Compiler and
  credo run the whole tree and main lands clean of both, so they have no
  baseline to ask.
  """
  @spec baseline_files([problem()]) :: %{String.t() => [String.t()]}
  def baseline_files(problems) do
    problems
    |> Enum.filter(&(&1.source in @baseline_sources and located?(&1.file_path)))
    |> Enum.group_by(& &1.source, & &1.file_path)
    |> Map.new(fn {source, paths} -> {source, Enum.uniq(paths)} end)
  end

  @doc "`{:rerun, source}` for a single finding, else `:no`."
  @spec lone_failure([problem()]) :: {:rerun, String.t()} | :no
  def lone_failure([%{source: source}]), do: {:rerun, source}
  def lone_failure(_problems), do: :no

  @doc """
  The one candidate every finding's file belongs to, if there is exactly one.

  `changed` maps each candidate's id to the files it changed. A finding with no
  file (or the analyzer's `"unknown"`) cannot be attributed, so neither can the
  batch.
  """
  @spec culprit([problem()], %{optional(term()) => [String.t()]}) :: {:culprit, term()} | :unknown
  def culprit([], _changed), do: :unknown

  def culprit(problems, changed) do
    paths = Enum.map(problems, & &1.file_path)

    if Enum.all?(paths, &located?/1) do
      paths |> Enum.uniq() |> owners(changed) |> single()
    else
      :unknown
    end
  end

  defp located?(path), do: is_binary(path) and path not in ["", "unknown"]

  # Each finding's file must be touched by exactly the same single candidate.
  defp owners(paths, changed) do
    Enum.map(paths, fn path ->
      for {id, files} <- changed, path in files, do: id
    end)
  end

  defp single(owners) do
    case owners |> Enum.uniq() do
      [[id]] -> {:culprit, id}
      _ -> :unknown
    end
  end

  @doc "The first half to gate next, and the rest, which go back to the queue in order."
  @spec split([term()]) :: {[term()], [term()]}
  def split(entries), do: Enum.split(entries, div(length(entries) + 1, 2))
end
