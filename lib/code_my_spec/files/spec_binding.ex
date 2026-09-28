defmodule CodeMySpec.Files.SpecBinding do
  @moduledoc """
  Binds each spex file to the criterion its `spex` call names.

  The scanner reads the number out of the file (`spex "…", criterion: 12`) and
  carries it in `validation_errors["data"]`. This turns it into
  `criterion_id`, and takes the file's story from the criterion, so neither
  the filename nor the directory decides anything.

  A number that binds to nothing makes the file invalid, with a reason the
  agent can act on: a number the project does not have, a retired criterion,
  or a criterion another spex already covers. The file that held the criterion
  first keeps it.
  """

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.BddSpecs.ContentCheck
  alias CodeMySpec.Files
  alias CodeMySpec.Users.Scope

  @doc """
  Bind the spex entries among `entries`; every other entry gets a nil
  `criterion_id`.

  `complete?` says `entries` is the whole of this working copy's tree, as a
  manifest is. Then a file not among them is gone and holds nothing, which is
  what lets a moved spec keep its criterion. An incremental sync passes
  `false`, and every stored binding still counts.
  """
  @spec bind(Scope.t(), [map()], boolean()) :: [map()]
  def bind(%Scope{} = scope, entries, complete?) do
    criteria =
      entries
      |> Enum.flat_map(&List.wrap(named(&1)))
      |> Enum.uniq()
      |> then(&AcceptanceCriteria.list_criteria_by_number(scope, &1))
      |> Map.new(&{&1.number, &1})

    held = held(scope, criteria, entries, complete?)

    {bound, _held} =
      entries
      |> Enum.sort_by(& &1.path)
      |> Enum.map_reduce(held, &bind_entry(&1, criteria, &2))

    bound
  end

  defp held(scope, criteria, entries, complete?) do
    stored = Files.spec_paths_by_criterion(scope, criteria |> Map.values() |> Enum.map(& &1.id))

    if complete? do
      present = MapSet.new(entries, & &1.path)
      Map.filter(stored, fn {_id, path} -> MapSet.member?(present, path) end)
    else
      stored
    end
  end

  defp bind_entry(entry, criteria, held) do
    case named(entry) do
      nil -> {Map.put(entry, :criterion_id, nil), held}
      number -> bind_number(entry, Map.get(criteria, number), number, held)
    end
  end

  defp bind_number(entry, nil, number, held),
    do: {invalid(entry, {:unknown_criterion, number}), held}

  defp bind_number(entry, %{retired_at: %DateTime{}}, number, held),
    do: {invalid(entry, {:retired_criterion, number}), held}

  defp bind_number(entry, criterion, number, held) do
    case Map.get(held, criterion.id, entry.path) do
      path when path == entry.path ->
        {entry |> Map.put(:criterion_id, criterion.id) |> Map.put(:story_id, criterion.story_id),
         Map.put(held, criterion.id, entry.path)}

      covered_by ->
        {invalid(entry, {:duplicate_criterion, number, covered_by}), held}
    end
  end

  defp invalid(entry, reason) do
    entry
    |> Map.put(:criterion_id, nil)
    |> Map.put(:valid, false)
    |> Map.put(:validation_errors, %{
      "reason" => ContentCheck.describe(reason, entry.path),
      "data" => entry.validation_errors["data"]
    })
  end

  # The number a valid spex names. Keys arrive as strings: a harness's entry
  # has crossed the wire as JSON.
  defp named(%{role: :bdd_spec, valid: true, validation_errors: %{"data" => %{"criterion" => n}}})
       when is_integer(n),
       do: n

  defp named(_entry), do: nil
end
