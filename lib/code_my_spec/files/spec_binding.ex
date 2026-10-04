defmodule CodeMySpec.Files.SpecBinding do
  @moduledoc """
  A spex file and the criterion its `spex` call names.

  The scanner reads the number out of the file (`spex "…", criterion: 12`)
  and carries it in `validation_errors["data"]`. At sync, `bind/2` records it
  as `criterion_number` and takes the file's story from that criterion, so
  neither the filename nor the directory decides anything.

  Which criterion a file covers is not stored: it is the join of
  `criterion_number` and `criteria.number`. A criterion retired, restored or
  created later changes the answer in its own transaction, with nothing to
  re-project. For the same reason `problems/2` works out, when asked, which
  files name a number that binds to nothing — unknown, retired, or already
  covered by another file.
  """

  alias CodeMySpec.BddSpecs.ContentCheck
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.Users.Scope

  @doc """
  Record the number each spex entry names, and its story when the project has
  that criterion. Every other entry gets a nil `criterion_number`.
  """
  @spec bind(Scope.t(), [map()]) :: [map()]
  def bind(%Scope{} = scope, entries) do
    criteria = criteria_named(scope, entries)
    Enum.map(entries, &bind_entry(&1, criteria))
  end

  @doc """
  Why each of `files` covers nothing although it names a criterion, as
  `%{path => reason}`. `files` are one working copy's spex rows. A file absent
  from the result either covers its criterion or is invalid for its content.
  """
  @spec problems(Scope.t(), [map()]) :: %{String.t() => String.t()}
  def problems(%Scope{} = scope, files) do
    named = Enum.filter(files, &(&1.role == :bdd_spec and is_integer(&1.criterion_number)))
    criteria = criteria_named(scope, named)

    {problems, _first} =
      named
      |> Enum.sort_by(&{recorded_at(&1), &1.path})
      |> Enum.reduce({%{}, %{}}, fn file, {problems, first} ->
        case problem(file, Map.get(criteria, file.criterion_number), first) do
          nil ->
            {problems, Map.put_new(first, file.criterion_number, file.path)}

          reason ->
            {Map.put(problems, file.path, ContentCheck.describe(reason, file.path)), first}
        end
      end)

    problems
  end

  defp problem(file, nil, _first), do: {:unknown_criterion, file.criterion_number}

  defp problem(file, %{retired_at: %DateTime{}}, _first),
    do: {:retired_criterion, file.criterion_number}

  defp problem(file, _criterion, first) do
    case Map.get(first, file.criterion_number) do
      nil -> nil
      covered_by -> {:duplicate_criterion, file.criterion_number, covered_by}
    end
  end

  defp bind_entry(entry, criteria) do
    case named(entry) do
      nil ->
        Map.put(entry, :criterion_number, nil)

      number ->
        entry
        |> Map.put(:criterion_number, number)
        |> put_story(Map.get(criteria, number))
    end
  end

  # The file that held the number first keeps it. A row not yet written sorts
  # after every recorded one.
  defp recorded_at(%{inserted_at: %NaiveDateTime{} = at}), do: NaiveDateTime.to_iso8601(at)
  defp recorded_at(_file), do: "~"

  defp put_story(entry, nil), do: entry
  defp put_story(entry, criterion), do: Map.put(entry, :story_id, criterion.story_id)

  defp criteria_named(scope, entries) do
    entries
    |> Enum.flat_map(&List.wrap(Map.get(&1, :criterion_number) || named(&1)))
    |> Enum.uniq()
    |> then(&AcceptanceCriteria.list_criteria_by_number(scope, &1))
    |> Map.new(&{&1.number, &1})
  end

  # The number a spex names, valid or not. Keys arrive as strings: a harness's
  # entry has crossed the wire as JSON.
  defp named(%{role: :bdd_spec, validation_errors: %{"data" => %{"criterion" => n}}})
       when is_integer(n),
       do: n

  defp named(_entry), do: nil
end
