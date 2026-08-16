defmodule CodeMySpec.Analysis.Signatures do
  @moduledoc """
  What a run found, in a form the next run can be compared against.

  `problems` rows are replaced per source per file on every sweep and carry no
  run id, so the moment a run finishes, what the previous one found is gone.
  That makes the natural verification loop — sweep, change something, sweep
  again, compare — impossible to close: by the time you have the *after*, the
  *before* no longer exists.

  It is not a hypothetical gap. A resolution was written on this project
  claiming "zero problems matching the signature, where the prior sweep carried
  the leak", against a prior sweep nobody had checked and which could no longer
  be checked. The claim was unfalsifiable at the moment it was made, which is
  exactly why it went in unchallenged (`08d3f858`).

  A raw failure count survives in the run row and cannot substitute: counts move
  for unrelated reasons — a partition migration, an unrelated fix in the same
  window — so a count can say something changed but never *which* finding went
  away. "Which one" is the question an investigation actually asks.

  Written into the run's existing `stats` map rather than a new table or a
  column on `problems`. `stats` is already jsonb and already round-trips, so
  this changes nothing about how problems are written or read — and in
  particular nothing about what the stop hook gates on. A gate that quietly
  stops blocking is the failure mode this codebase has paid for repeatedly; it
  is not worth risking to add a diagnostic.
  """

  alias CodeMySpec.Analysis.Run

  @key "problem_signatures"
  @count_key "problem_signature_count"

  # Enough to identify a finding across runs without storing its whole message.
  # A full sweep here produces ~30 problems and credo alone can produce 130, so
  # the cap bounds a run row at roughly 16 KB.
  @max_signatures 400
  @message_head 80

  @doc """
  Stable identifiers for `problems`, sorted, deduplicated and capped.

  Sorted so two runs' lists can be compared directly, and because insertion
  order is not stable across runs. Deduplicated because two findings can share a
  file, line and message head — a repeated credo rule on one line — and for
  comparison purposes they are the same finding.
  """
  @spec of([map() | struct()]) :: [String.t()]
  def of(problems) when is_list(problems) do
    problems
    |> Enum.map(&signature/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_signatures)
  end

  @doc """
  Merge `signatures` into a run's `stats` map.

  Records the true count alongside, so a capped list still says how many there
  were. A truncated list that reports its own length would understate the run
  and read as findings having disappeared — the precise misreading this module
  exists to prevent.
  """
  @spec put(map() | nil, [String.t()]) :: map()
  def put(stats, signatures) do
    stats
    |> normalize_stats()
    |> Map.put(@key, signatures)
    |> Map.put(@count_key, length(signatures))
  end

  @doc "Signatures recorded on a finished run, or `[]` if it predates this."
  @spec read(Run.t() | nil) :: [String.t()]
  def read(nil), do: []

  def read(%Run{stats: stats}) when is_map(stats) do
    case Map.get(stats, @key) do
      list when is_list(list) -> list
      _absent -> []
    end
  end

  def read(%Run{}), do: []

  @doc """
  What went away and what is new, between a previous run and current signatures.

  `gone` are signatures the previous run recorded and this one did not; `new`
  are the reverse.
  """
  @spec delta(Run.t() | nil, [String.t()]) :: %{gone: [String.t()], new: [String.t()]}
  def delta(previous, signatures) do
    before = MapSet.new(read(previous))
    now = MapSet.new(signatures)

    %{
      gone: before |> MapSet.difference(now) |> Enum.sort(),
      new: now |> MapSet.difference(before) |> Enum.sort()
    }
  end

  @doc """
  A short " — N gone, M new since the last sweep" for the reconcile log line.

  Empty when there is nothing to say, including when the previous run predates
  signature recording: an absent baseline and an unchanged one are different
  facts, and reporting "0 gone, 0 new" for the first would assert a comparison
  that never happened.
  """
  @spec delta_suffix(Run.t() | nil, [String.t()]) :: String.t()
  def delta_suffix(previous, signatures) do
    previous
    |> read()
    |> suffix_for(previous, signatures)
  end

  defp suffix_for([], _previous, _signatures), do: ""

  defp suffix_for(_recorded, previous, signatures) do
    %{gone: gone, new: added} = delta(previous, signatures)

    describe(length(gone), length(added))
  end

  defp describe(0, 0), do: " — unchanged since the last sweep"
  defp describe(gone, added), do: " — #{gone} gone, #{added} new since the last sweep"

  # `file:line message-head`. Line is included because two findings in one file
  # are ordinarily different findings, and the message head because one line can
  # carry several. Not the full message: it is unbounded, and a run row is not a
  # place to store a second copy of every problem.
  defp signature(problem) do
    "#{field(problem, :file_path)}:#{field(problem, :line)} #{message_head(problem)}"
  end

  defp message_head(problem) do
    problem
    |> field(:message)
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @message_head)
  end

  defp field(problem, key), do: Map.get(problem, key)

  defp normalize_stats(stats) when is_map(stats), do: stats
  defp normalize_stats(_stats), do: %{}
end
