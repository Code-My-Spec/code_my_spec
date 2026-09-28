defmodule CodeMySpec.BddSpecs.Stamp do
  @moduledoc """
  One-off migration: name each existing spex's criterion inside the file.

  Spex written before story 1077 say which criterion they cover only through
  a recorded `criteria.spec_path` or a `criterion_<id>_` filename. This finds
  the criterion by those two, in that order, adds `criterion: <number>` to the
  file's `spex` call and moves the file to `test/spex/<story>_<slug>/criterion_<number>_<slug>_spex.exs`.

  Nothing is guessed. A file that matches no criterion, names a retired one, or
  whose `spex` call cannot be found is reported and left alone for a person
  to decide.

  Pure: `plan/3` takes the files and the criteria and returns what to do.
  `Mix.Tasks.Cms.StampSpex` reads and writes.
  """

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.BddSpecs.ContentCheck

  @type action ::
          %{
            path: String.t(),
            action: :stamp,
            number: pos_integer(),
            to: String.t(),
            content: String.t(),
            criterion: map()
          }
          | %{path: String.t(), action: :skip, number: pos_integer()}
          | %{path: String.t(), action: :unmatched, why: String.t()}

  @doc """
  `files` is `[{path, content}]`; `criteria` every criterion in the project,
  retired included; `stories` a map of story id to story.
  """
  @spec plan([{String.t(), String.t()}], [map()], %{integer() => map()}) :: [action()]
  def plan(files, criteria, stories) do
    by_path = for c <- criteria, is_binary(c.spec_path) and c.spec_path != "", into: %{}, do: {c.spec_path, c}
    by_id = Map.new(criteria, &{&1.id, &1})

    {actions, _taken} =
      files
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_reduce(MapSet.new(), fn {path, content}, taken ->
        action = plan_file(path, content, by_path, by_id, stories, taken)
        {action, mark_taken(taken, action)}
      end)

    actions
  end

  defp plan_file(path, content, by_path, by_id, stories, taken) do
    case ContentCheck.named_criterion(content, path) do
      nil ->
        criterion = Map.get(by_path, path) || Map.get(by_id, filename_id(path))
        stamp_file(path, content, criterion, stories, taken)

      number ->
        %{path: path, action: :skip, number: number}
    end
  end

  defp stamp_file(path, _content, nil, _stories, _taken),
    do: unmatched(path, "no recorded spec_path and no criterion with the id in its filename")

  defp stamp_file(path, _content, %{retired_at: %DateTime{}} = c, _stories, _taken),
    do: unmatched(path, "criterion #{c.number} is retired")

  defp stamp_file(path, content, criterion, stories, taken) do
    with false <- MapSet.member?(taken, criterion.id),
         {:ok, stamped} <- stamp(content, criterion.number) do
      story = Map.fetch!(stories, criterion.story_id)
      to = BddSpecs.spec_file_path(story, %{criterion | spec_path: nil})
      %{path: path, action: :stamp, number: criterion.number, to: to, content: stamped, criterion: criterion}
    else
      true -> unmatched(path, "criterion #{criterion.number} is already covered by another file")
      :error -> unmatched(path, "no `spex \"…\" do` call found; add `criterion: #{criterion.number}` by hand")
    end
  end

  @doc "Add `criterion: number` to the first `spex \"…\" do` line."
  @spec stamp(String.t(), pos_integer()) :: {:ok, String.t()} | :error
  def stamp(content, number) do
    # Options may run over several lines; the head ends at the first `do` that
    # closes a line.
    pattern = ~r/^(\s*spex\s+"(?:[^"\\]|\\.)*"(?:\s*,.*?)?)\s+do[ \t]*$/ms

    case Regex.run(pattern, content, return: :index) do
      [{start, length}, {head_start, head_length}] ->
        head = binary_part(content, head_start, head_length)
        line = "#{head}, criterion: #{number} do"
        rest = binary_part(content, start + length, byte_size(content) - start - length)
        {:ok, binary_part(content, 0, start) <> line <> rest}

      nil ->
        :error
    end
  end

  defp filename_id(path) do
    case Regex.run(~r/^criterion_(\d+)_/, Path.basename(path)) do
      [_, id] -> String.to_integer(id)
      nil -> nil
    end
  end

  defp mark_taken(taken, %{action: :stamp, criterion: criterion}), do: MapSet.put(taken, criterion.id)
  defp mark_taken(taken, _action), do: taken

  defp unmatched(path, why), do: %{path: path, action: :unmatched, why: why}
end
