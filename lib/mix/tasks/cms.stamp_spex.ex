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

  alias CodeMySpec.BddSpecs.Stamp
  alias CodeMySpec.Projects
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria

  @shortdoc "Stamp criterion numbers into existing spex files"

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [apply: :boolean, root: :string])

    case Keyword.fetch(opts, :root) do
      {:ok, root} -> run_in(Path.expand(root), Keyword.get(opts, :apply, false))
      :error -> Mix.shell().error("Usage: mix cms.stamp_spex --root <checkout> [--apply]")
    end
  end

  defp run_in(root, apply?) do
    start_minimal()

    # A dry run reads the graph through a scope resolved from whatever
    # `--root` names, which is routinely a worktree used only to inspect it --
    # never that checkout's own canonical location. `sync_local_path: false`
    # keeps that read from repointing the project there (c1b2d03a).
    case Projects.scope_from_local_config(root, sync_local_path: false) do
      {:ok, scope} -> stamp(scope, root, apply?)
      {:error, reason} -> Mix.shell().error("Failed to load project scope: #{inspect(reason)}")
    end
  end

  # `app.config`, not `app.start`: runtime.exs still runs, so the Repo is
  # configured the way the app would configure it, but nothing is supervised
  # beyond what this task uses. `app.start` booted the whole application in
  # this task's BEAM -- background workers included, against the shared
  # database a dry run has no business touching (c1b2d03a). Same shape as
  # `Mix.Tasks.Cms.Seed`'s own preamble.
  defp start_minimal do
    Mix.Task.run("app.config")

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    {:ok, _} = CodeMySpec.Vault.start_link([])
    {:ok, _} = CodeMySpec.Repo.start_link([])

    # `AcceptanceCriteria.update_criterion/3` broadcasts on write; without the
    # registry that surfaces mid-apply as `** (ArgumentError) unknown
    # registry: CodeMySpec.PubSub`, which reads as a broken context rather
    # than a missing process.
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: CodeMySpec.PubSub)
  end

  defp stamp(scope, root, apply?) do
    {:ok, stories} = Stories.list_project_stories(scope)
    stories = Map.new(stories, &{&1.id, &1})

    criteria =
      Enum.flat_map(Map.keys(stories), &AcceptanceCriteria.list_all_story_criteria(scope, &1))

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

    Mix.shell().info(
      "stamp: #{counts[:stamp] || 0}, already named: #{counts[:skip] || 0}, unmatched: #{counts[:unmatched] || 0}"
    )

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

    {:ok, _} =
      AcceptanceCriteria.update_criterion(scope, action.criterion, %{spec_path: action.to})
  end

  defp carry_out(_action, _scope, _root), do: :ok

  defp remove_if_empty(dir) do
    case File.ls(dir) do
      {:ok, []} -> File.rmdir!(dir)
      _ -> :ok
    end
  end
end
