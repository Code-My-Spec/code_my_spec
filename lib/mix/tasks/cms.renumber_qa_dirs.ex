defmodule Mix.Tasks.Cms.RenumberQaDirs do
  use Boundary, classify_to: CodeMySpec

  @moduledoc """
  Rename QA evidence directories from story id to story number.

      mix cms.renumber_qa_dirs --root <checkout>            # dry run: prints the plan
      mix cms.renumber_qa_dirs --root <checkout> --apply    # renames

  `.code_my_spec/qa/<story_id>/` becomes `.code_my_spec/qa/<story_number>/`. The
  project comes from the checkout's `.code_my_spec/config.yml`.

  One-off, and run it once: a directory name is read as an id, so a directory
  already named by number would be read as an id on a second run. Directories
  whose name is no story id here are left alone. A rename whose target already
  exists (and is not itself being moved) is refused and reported. Renames go
  through a temporary name so chains and swaps between ids and numbers settle
  in one pass.
  """

  use Mix.Task

  alias CodeMySpec.Paths
  alias CodeMySpec.Projects
  alias CodeMySpec.Stories

  @shortdoc "Rename .code_my_spec/qa/<id>/ directories to <story number>"

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [apply: :boolean, root: :string])

    case Keyword.fetch(opts, :root) do
      {:ok, root} -> run_in(Path.expand(root), Keyword.get(opts, :apply, false))
      :error -> Mix.shell().error("Usage: mix cms.renumber_qa_dirs --root <checkout> [--apply]")
    end
  end

  defp run_in(root, apply?) do
    Mix.Task.run("app.start")

    case Projects.scope_from_local_config(root) do
      {:ok, scope} -> renumber(scope, Path.join(root, Paths.qa_dir()), apply?)
      {:error, reason} -> Mix.shell().error("Failed to load project scope: #{inspect(reason)}")
    end
  end

  defp renumber(scope, qa_dir, apply?) do
    names =
      case File.ls(qa_dir) do
        {:ok, entries} -> Enum.filter(entries, &File.dir?(Path.join(qa_dir, &1)))
        {:error, _} -> []
      end

    plan = plan(names, Stories.story_numbers(scope))
    report(plan)

    if apply?, do: carry_out(plan, qa_dir)
  end

  @doc """
  The rename plan for the directory `names` under the qa dir, given
  `%{story_id => story_number}`.

  Each entry is `%{action: :rename | :skip | :unknown | :collision, from: name}`,
  with `:to` on `:rename` and `:collision`. Names that are not integers
  (`scripts`, …) are not stories and do not appear.
  """
  @spec plan([String.t()], %{optional(integer()) => integer()}) :: [map()]
  def plan(names, numbers_by_id) do
    candidates =
      for name <- names, {id, ""} <- [Integer.parse(name)] do
        case Map.fetch(numbers_by_id, id) do
          {:ok, number} when number == id -> %{action: :skip, from: name}
          {:ok, number} -> %{action: :rename, from: name, to: to_string(number)}
          :error -> %{action: :unknown, from: name}
        end
      end

    moving = for %{action: :rename, from: from} <- candidates, into: MapSet.new(), do: from
    staying = MapSet.difference(MapSet.new(names), moving)

    Enum.map(candidates, fn
      %{action: :rename, to: to} = entry ->
        if MapSet.member?(staying, to), do: %{entry | action: :collision}, else: entry

      entry ->
        entry
    end)
  end

  defp report(plan) do
    counts = Enum.frequencies_by(plan, & &1.action)

    Mix.shell().info(
      "rename: #{counts[:rename] || 0}, already numbered: #{counts[:skip] || 0}, " <>
        "no such story: #{counts[:unknown] || 0}, collisions: #{counts[:collision] || 0}"
    )

    for entry <- plan, entry.action in [:rename, :unknown, :collision] do
      Mix.shell().info("  #{describe(entry)}")
    end
  end

  defp describe(%{action: :rename, from: from, to: to}), do: "rename qa/#{from} -> qa/#{to}"
  defp describe(%{action: :unknown, from: from}), do: "leave  qa/#{from}: no story has id #{from}"

  defp describe(%{action: :collision, from: from, to: to}),
    do: "refuse qa/#{from} -> qa/#{to}: qa/#{to} already exists"

  # Two phases so a target that is itself a source (id 5 -> 7 while id 7 -> 5)
  # is vacated before anything lands on it.
  defp carry_out(plan, qa_dir) do
    renames = for %{action: :rename} = entry <- plan, do: entry

    Enum.each(renames, fn %{from: from} ->
      File.rename!(Path.join(qa_dir, from), Path.join(qa_dir, temp_name(from)))
    end)

    Enum.each(renames, fn %{from: from, to: to} ->
      File.rename!(Path.join(qa_dir, temp_name(from)), Path.join(qa_dir, to))
    end)

    Mix.shell().info("renamed #{length(renames)} directories")
  end

  defp temp_name(from), do: ".renumbering-#{from}"
end
