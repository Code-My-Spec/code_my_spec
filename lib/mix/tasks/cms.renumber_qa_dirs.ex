defmodule Mix.Tasks.Cms.RenumberQaDirs do
  use Boundary, classify_to: CodeMySpec

  @moduledoc """
  Move QA evidence directories from story id to story number.

      mix cms.renumber_qa_dirs --root <checkout>            # dry run: prints the plan
      mix cms.renumber_qa_dirs --root <checkout> --apply    # moves

  `.code_my_spec/qa/<story_id>/` becomes `.code_my_spec/qa/<story_number>/`. The
  project comes from the checkout's `.code_my_spec/config.yml`.

  A checkout's directories are already a mix: some were named when ids and
  numbers still coincided, some by number, most recent ones by id. So a name is
  only moved when it can only be an id. A name that is one story's id and
  another's number is decided by which story's title its brief carries, and
  left alone when it carries neither or both. A move onto a directory that is
  staying because it is already named by number merges into it; a file present
  in both keeps the target's and lands beside it as `<name>.from-<id><ext>`. A
  move onto a directory left alone is not made — whose evidence that is was
  never settled.
  """

  use Mix.Task

  import Ecto.Query

  alias CodeMySpec.Paths
  alias CodeMySpec.Projects
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story

  @shortdoc "Move .code_my_spec/qa/<id>/ directories to <story number>"

  @heading_files ~w(brief.md prompt.md result.md result_complete.md)

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
    dirs =
      case File.ls(qa_dir) do
        {:ok, entries} ->
          for name <- entries,
              File.dir?(Path.join(qa_dir, name)),
              do: {name, heading(qa_dir, name)}

        {:error, _} ->
          []
      end

    plan = plan(dirs, stories(scope))
    report(plan)

    if apply?, do: carry_out(plan, qa_dir)
  end

  # Retired stories included: their evidence is still theirs.
  defp stories(scope) do
    Repo.all(
      from s in Story,
        where: s.project_id == ^scope.active_project_id,
        select: %{id: s.id, number: s.number, title: s.title}
    )
  end

  # The opening of each brief-like file: enough to carry the story's title.
  defp heading(qa_dir, name) do
    Enum.map_join(@heading_files, "\n", fn file ->
      case File.read(Path.join([qa_dir, name, file])) do
        {:ok, body} -> String.slice(body, 0, 4000)
        _ -> ""
      end
    end)
  end

  @doc """
  The plan for `dirs` (`{name, brief_text}`) given the project's `stories`
  (`%{id, number, title}`).

  Each entry is `%{action: :move | :stay | :ambiguous | :unknown | :blocked,
  from: name}`, with `:to` on `:move` and `:blocked`. Names that are not
  integers (`scripts`, …) are not stories and do not appear.
  """
  @spec plan([{String.t(), String.t()}], [map()]) :: [map()]
  def plan(dirs, stories) do
    by_id = Map.new(stories, &{&1.id, &1})
    by_number = Map.new(stories, &{&1.number, &1})

    plan =
      for {name, heading} <- dirs, {n, ""} <- [Integer.parse(name)] do
        classify(name, heading, Map.get(by_id, n), Map.get(by_number, n))
      end

    unsettled =
      for %{action: a, from: from} <- plan,
          a in [:ambiguous, :unknown],
          into: MapSet.new(),
          do: from

    Enum.map(plan, fn
      %{action: :move, to: to} = entry ->
        if MapSet.member?(unsettled, to), do: %{entry | action: :blocked}, else: entry

      entry ->
        entry
    end)
  end

  defp classify(name, _heading, %{id: same, number: same}, _numbered),
    do: %{action: :stay, from: name}

  defp classify(name, _heading, %{number: number}, nil),
    do: %{action: :move, from: name, to: to_string(number)}

  defp classify(name, _heading, nil, %{}), do: %{action: :stay, from: name}
  defp classify(name, _heading, nil, nil), do: %{action: :unknown, from: name}

  defp classify(name, heading, by_id, numbered) do
    case {names?(heading, by_id), names?(heading, numbered)} do
      {true, false} -> %{action: :move, from: name, to: to_string(by_id.number)}
      {false, true} -> %{action: :stay, from: name}
      _ -> %{action: :ambiguous, from: name}
    end
  end

  defp names?(heading, %{title: title}) when is_binary(title) and title != "",
    do: String.contains?(String.downcase(heading), String.downcase(title))

  defp names?(_heading, _story), do: false

  defp report(plan) do
    counts = Enum.frequencies_by(plan, & &1.action)

    Mix.shell().info(
      "move: #{counts[:move] || 0}, stay: #{counts[:stay] || 0}, " <>
        "ambiguous: #{counts[:ambiguous] || 0}, blocked: #{counts[:blocked] || 0}, " <>
        "no such story: #{counts[:unknown] || 0}"
    )

    for entry <- plan, entry.action != :stay do
      Mix.shell().info("  #{describe(entry)}")
    end
  end

  defp describe(%{action: :move, from: from, to: to}), do: "move   qa/#{from} -> qa/#{to}"

  defp describe(%{action: :ambiguous, from: from}),
    do: "leave  qa/#{from}: ambiguous — an id and a number, and its brief settles neither"

  defp describe(%{action: :blocked, from: from, to: to}),
    do: "leave  qa/#{from}: blocked — its number's directory qa/#{to} is itself unsettled"

  defp describe(%{action: :unknown, from: from}), do: "leave  qa/#{from}: no such story"

  # Every source is vacated first, so a target that is itself a source is not
  # mistaken for evidence already sitting there.
  defp carry_out(plan, qa_dir) do
    moves = for %{action: :move} = entry <- plan, do: entry

    Enum.each(moves, fn %{from: from} ->
      File.rename!(Path.join(qa_dir, from), Path.join(qa_dir, temp_name(from)))
    end)

    Enum.each(moves, fn %{from: from, to: to} ->
      source = Path.join(qa_dir, temp_name(from))
      target = Path.join(qa_dir, to)

      if File.exists?(target), do: merge(source, target, from), else: File.rename!(source, target)
    end)

    Mix.shell().info("moved #{length(moves)} directories")
  end

  defp merge(source, target, from) do
    for entry <- File.ls!(source) do
      dest = Path.join(target, entry)
      dest = if File.exists?(dest), do: beside(dest, from), else: dest
      File.rename!(Path.join(source, entry), dest)
    end

    File.rmdir!(source)
  end

  defp beside(path, from) do
    ext = Path.extname(path)
    Path.rootname(path) <> ".from-#{from}" <> ext
  end

  defp temp_name(from), do: ".renumbering-#{from}"
end
