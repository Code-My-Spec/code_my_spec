defmodule Mix.Tasks.Cms.StampSpex do
  use Boundary, classify_to: CodeMySpec

  @moduledoc """
  Name each existing spex's criterion inside the file (story 1077).

      mix cms.stamp_spex --root <checkout>            # dry run: prints the plan
      mix cms.stamp_spex --root <checkout> --apply    # stamps, moves, records the new path

  The project comes from the checkout's `.code_my_spec/config.yml`. See
  `CodeMySpec.BddSpecs.Stamp` for how a file's criterion is found. Files it cannot match are listed and left alone.
  """

  use Mix.Task

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.BddSpecs.Stamp
  alias CodeMySpec.Projects
  alias CodeMySpec.Stories

  @shortdoc "Stamp criterion numbers into existing spex files"

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [apply: :boolean, root: :string])

    case Keyword.fetch(opts, :root) do
      {:ok, root} -> run_in(Path.expand(root), Keyword.get(opts, :apply, false))
      :error -> Mix.shell().error("Usage: mix cms.stamp_spex --root <checkout> [--apply]")
    end
  end

  defp run_in(root, apply?) do
    Mix.Task.run("app.start")

    case Projects.scope_from_local_config(root) do
      {:ok, scope} -> stamp(scope, root, apply?)
      {:error, reason} -> Mix.shell().error("Failed to load project scope: #{inspect(reason)}")
    end
  end

  defp stamp(scope, root, apply?) do
    {:ok, stories} = Stories.list_project_stories(scope)
    stories = Map.new(stories, &{&1.id, &1})
    criteria = Enum.flat_map(Map.keys(stories), &AcceptanceCriteria.list_all_story_criteria(scope, &1))

    files =
      root
      |> Path.join("test/spex/**/*_spex.exs")
      |> Path.wildcard()
      |> Enum.map(&{Path.relative_to(&1, root), File.read!(&1)})

    plan = Stamp.plan(files, criteria, stories)
    report(plan)

    if apply?, do: Enum.each(plan, &carry_out(&1, scope, root))
  end

  defp report(plan) do
    counts = Enum.frequencies_by(plan, & &1.action)
    Mix.shell().info("stamp: #{counts[:stamp] || 0}, already named: #{counts[:skip] || 0}, unmatched: #{counts[:unmatched] || 0}")

    for %{action: :unmatched, path: path, why: why} <- plan do
      Mix.shell().info("  unmatched #{path}: #{why}")
    end
  end

  defp carry_out(%{action: :stamp} = action, scope, root) do
    to = Path.join(root, action.to)
    File.mkdir_p!(Path.dirname(to))
    File.write!(to, action.content)

    if action.to != action.path do
      File.rm!(Path.join(root, action.path))
      remove_if_empty(Path.dirname(Path.join(root, action.path)))
    end

    {:ok, _} = AcceptanceCriteria.update_criterion(scope, action.criterion, %{spec_path: action.to})
  end

  defp carry_out(_action, _scope, _root), do: :ok

  defp remove_if_empty(dir) do
    case File.ls(dir) do
      {:ok, []} -> File.rmdir!(dir)
      _ -> :ok
    end
  end
end
