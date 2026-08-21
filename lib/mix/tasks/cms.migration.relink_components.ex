defmodule Mix.Tasks.Cms.Migration.RelinkComponents do
  @shortdoc "Finish a migration by linking its stories to the components that have since synced"

  @moduledoc """
  Link a migrated project's stories to the components they name.

      mix cms.migration.relink_components <project-id>

  ## Why a migration needs a second step

  Components are derived. `CodeMySpec.Migration` deliberately does not carry
  them — the destination rebuilds them from the working copy on first sync — so
  the import resolves each story's `component_module_name` against the components
  that exist *at import time*, which on a first migration is none of them. The
  working copy has not synced yet.

  So every story lands unlinked, and the project reports 0/0 satisfied for
  everything, which reads as "nothing is done" rather than "nothing is linked".
  Measured 2026-08-21 on Broken Oaths: 52 stories, 38 linked in the source and 0
  in the destination, against 171 components that arrived minutes later and
  matched by name exactly.

  Run this once, after the working copy has synced. It is safe to run again — it
  only fills a `component_id` that is null, and never re-points a story somebody
  has since pointed somewhere else.

  ## Why it is a task and not part of the sync

  It was in `Files.ComponentSync` first. That runs on every sync of every
  project, several times a minute, to do something that matters once in a
  project's life — and a rule that only ever fires for one project is one nobody
  reading the sync path would expect to find there. Work that matters once is
  named and run once.
  """

  use Boundary, classify_to: CodeMySpec
  use Mix.Task

  alias CodeMySpec.Migration
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @impl Mix.Task
  def run([project_id]) when is_binary(project_id) do
    Mix.Task.run("app.start")

    case Projects.get_project_by_id(project_id) do
      nil -> Mix.raise("No project #{project_id}")
      project -> relink(project)
    end
  end

  def run(_args) do
    Mix.shell().error("""
    Usage:
      mix cms.migration.relink_components <project-id>

    Run it once after a migrated project's working copy has synced, which is
    what creates the components its stories name.
    """)

    exit({:shutdown, 1})
  end

  defp relink(project) do
    scope = %Scope{active_project_id: project.id, active_account_id: project.account_id}

    {:ok, linked} = Migration.relink_components(scope)

    Mix.shell().info(report(project, linked))
  end

  defp report(project, 0) do
    """

    #{project.name}: nothing to link.

    Either this project did not migrate, or its stories are already linked, or
    the components they name have not synced yet — a story is only linked to a
    component that exists. If you expected links, check that the working copy
    has synced and run this again.
    """
  end

  defp report(project, linked) do
    """

    #{project.name}: linked #{linked} story/stories to their components.
    """
  end
end
