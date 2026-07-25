defmodule Mix.Tasks.Cms.Content.Publish do
  @moduledoc """
  Publish a project's markdown content to its deployed site from the command
  line, without opening the local harness UI.

  Runs the same two steps the Content LiveView drives:

  1. `ContentPublishing.sync/1` — parse every markdown file under the project's
     `content_source_path` into the local snapshot and upload any images to the
     project's image bucket.
  2. `ContentPublishing.publish/1` — write a content blob plus an integrity
     manifest to the project's content bucket, then POST a pull trigger to the
     deployed client so it pulls and atomically replaces its content.

  Note that committing and pushing the content repo does **not** publish. Git is
  version control here; this task is what moves content to the site.

  ## CLI env is required

  Content publishing lives in the local harness, which runs on SQLite. Run this
  under a CLI env or the task aborts before touching anything:

      MIX_ENV=dev_cli mix cms.content.publish

  ## The target is not what the env name suggests

  Each CLI env reads a different SQLite database, and each database stores its
  own `client_api_url`. As of this writing they are inverted: `dev_cli`
  (`cli_dev.db`) points at production `codemyspec.com`, while `prod_cli`
  (`cli.db`) points at `dev.codemyspec.com`. Do not infer the target from the
  env name. This task prints the resolved target and asks before publishing, so
  read the banner rather than trusting the flag you typed.

  ## Usage

      # Show the target, sync, confirm, publish
      MIX_ENV=dev_cli mix cms.content.publish

      # A different project
      MIX_ENV=dev_cli mix cms.content.publish --project "Get Ai Traffic"

      # Parse and stage only. No S3 writes, no pull trigger.
      MIX_ENV=dev_cli mix cms.content.publish --sync-only

      # Skip the confirmation prompt (CI, scripts)
      MIX_ENV=dev_cli mix cms.content.publish --yes

  A file with frontmatter errors is staged as an error row and blocks the
  publish. The task names every offending file so the fix is a re-run away.
  """

  use Boundary, classify_to: CodeMySpec
  use Mix.Task

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.ContentPublishing
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @shortdoc "Publish a project's markdown content to its deployed site"

  @default_project "Code My Spec"

  @switches [project: :string, sync_only: :boolean, yes: :boolean]
  @aliases [p: :project, y: :yes]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    ensure_cli_env!()
    Mix.Task.run("app.start")

    project = fetch_project!(Keyword.get(opts, :project, @default_project))
    scope = build_scope!(project)

    print_target(project)
    sync!(scope)

    if Keyword.get(opts, :sync_only, false) do
      Mix.shell().info("\nStopped after sync (--sync-only). Nothing published.")
    else
      confirm!(project, Keyword.get(opts, :yes, false))
      publish!(scope)
    end
  end

  # The adapter is compiled in per env. Postgres means we booted a server env,
  # where the content snapshot tables aren't the ones the harness writes to.
  defp ensure_cli_env! do
    adapter = Application.get_env(:code_my_spec, :adapter, Ecto.Adapters.Postgres)

    unless adapter == Ecto.Adapters.SQLite3 do
      Mix.shell().error("""
      Content publishing needs a CLI env (SQLite), got #{inspect(adapter)}.

      Re-run as:

          MIX_ENV=dev_cli mix cms.content.publish
      """)

      System.halt(1)
    end
  end

  defp fetch_project!(name) do
    case Projects.get_project_by_name(name) do
      {:ok, project} ->
        project

      {:error, :not_found} ->
        Mix.shell().error("No project named #{inspect(name)} in #{db_path()}.\n")
        Mix.shell().error("Projects with a content source configured:")

        Enum.each(publishable_projects(), fn p ->
          Mix.shell().error("  #{p.name} -> #{p.client_api_url}")
        end)

        System.halt(1)
    end
  end

  defp build_scope!(project) do
    case Scope.for_local_project(project) do
      {:ok, scope} ->
        scope

      {:error, :no_local_path} ->
        Mix.shell().error("""
        Project #{inspect(project.name)} has no local_path, so there's no
        working directory to read content from. Link it in the harness first.
        """)

        System.halt(1)
    end
  end

  defp print_target(project) do
    Mix.shell().info("""

    Publish target
      project     #{project.name}
      database    #{db_path()}
      source      #{project.content_source_path || "(none)"}
      content     #{project.content_bucket || "(none)"}
      images      #{project.image_bucket || "(none)"}
      client      #{project.client_api_url || "(none)"}#{production_warning(project)}
    """)
  end

  defp production_warning(%{client_api_url: url}) when is_binary(url) do
    if String.contains?(url, "dev.") or String.contains?(url, "localhost") do
      ""
    else
      "   <-- PRODUCTION"
    end
  end

  defp production_warning(_), do: ""

  defp sync!(scope) do
    case ContentPublishing.sync(scope) do
      {:ok, counts} ->
        Mix.shell().info(
          "Synced #{counts.success} file(s), #{counts.error} error(s), " <>
            "#{Map.get(counts, :images_synced, 0)} image(s) uploaded, " <>
            "#{Map.get(counts, :images_failed, 0)} image failure(s)."
        )

        report_parse_errors(scope, counts)

      {:error, :no_source_path} ->
        Mix.shell().error("""
        This project has no content_source_path, so there's nothing to parse.
        Set one in the harness content settings.
        """)

        System.halt(1)
    end
  end

  defp report_parse_errors(_scope, %{error: 0}), do: :ok

  defp report_parse_errors(scope, _counts) do
    Mix.shell().error("\nFiles that failed to parse (these block the publish):")

    scope
    |> ContentPublishing.list_snapshot()
    |> Enum.filter(&(&1.parse_status == :error))
    |> Enum.each(fn row ->
      filename = get_in(row.metadata, ["filename"]) || "(unknown file)"
      Mix.shell().error("  #{filename}: #{format_errors(row.parse_errors)}")
    end)

    Mix.shell().error("\nFix the frontmatter and re-run.")
    System.halt(1)
  end

  defp format_errors(nil), do: "unknown error"

  defp format_errors(errors) when is_map(errors) do
    errors
    |> Enum.map_join("; ", fn {field, detail} -> "#{field} #{inspect(detail)}" end)
  end

  defp format_errors(other), do: inspect(other)

  defp confirm!(_project, true), do: :ok

  defp confirm!(project, _yes) do
    unless Mix.shell().yes?("Publish to #{project.client_api_url}?") do
      Mix.shell().info("Aborted. Nothing published.")
      System.halt(0)
    end
  end

  defp publish!(scope) do
    case ContentPublishing.publish(scope) do
      {:ok, result} ->
        by_type =
          result
          |> Map.get(:counts, %{})
          |> Enum.map_join(", ", fn {type, n} -> "#{n} #{type}" end)

        Mix.shell().info("""

        Published #{result.total} item(s): #{by_type}
          manifest  #{result[:manifest_url]}
          sync_id   #{result[:sync_id]}
        """)

      {:error, %{message: message}} ->
        Mix.shell().error("\nPublish failed: #{message}")
        System.halt(1)
    end
  end

  # Deliberately not Projects.list_projects/1: that needs an account scope, and
  # this runs before any project (and so any scope) is resolved.
  defp publishable_projects do
    Repo.all(
      from p in Project,
        where: not is_nil(p.content_source_path) and p.content_source_path != "",
        order_by: p.name
    )
  end

  defp db_path do
    Application.get_env(:code_my_spec, CodeMySpec.Repo, [])
    |> Keyword.get(:database, "(unknown)")
  end
end
