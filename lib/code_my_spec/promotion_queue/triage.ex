defmodule CodeMySpec.PromotionQueue.Triage do
  @moduledoc """
  What a red batch does next, decided from its findings alone.

  In order, cheapest first:

    1. **Attribute before bisecting.** When every finding sits in a file only
       one candidate changed, that candidate is the culprit and the rest are
       re-gated without it — no bisect needed.
    2. **Otherwise bisect.** Gate the first half; a green half lands, a red one
       is split again, and a red batch of one is ejected.
  """

  @type problem :: %{required(:source) => String.t(), required(:file_path) => String.t() | nil}

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
