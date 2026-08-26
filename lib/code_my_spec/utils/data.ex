defmodule CodeMySpec.Utils.Data do
  @moduledoc """
  Moves a single project — and only that project — between environments.

  This used to sync a whole account: every project it owned, wiped and
  reinserted together. That meant migrating one project dragged along
  whatever else lived on the account (other real projects, throwaway
  fixtures), and its wipe resolved "which accounts does this touch" by
  walking from the target account to its members' user ids and back out to
  every account those users belong to — deleting all of them, including ones
  nobody meant to touch, whenever a user happened to hold membership in more
  than one. Scoped to a project id instead, neither failure mode has
  anywhere to occur: a project belongs to exactly one account, never several.

  Assumes the destination account already exists — a project cannot be
  created under an account that isn't there, and this makes no attempt to
  create one.
  """

  require Logger

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias PaperTrail.Version

  import Ecto.Query

  @doc """
  Imports exactly one project's data — the project row, its components, and
  its stories/versions. Never touches the account, its members, its users, or
  any other project under that account.
  """
  def import_project(file_path, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    Logger.info("Importing project from #{file_path}...")

    json = File.read!(file_path)
    data = Jason.decode!(json, keys: :atoms)

    if dry_run do
      Logger.info("[DRY RUN] Would import:")
      Logger.info("  - Project: #{data.project.name}")
      Logger.info("  - #{length(data.components)} components")
      Logger.info("  - #{length(data.stories || [])} stories")
      Logger.info("  - #{length(data.versions || [])} versions")
    else
      Repo.transaction(fn ->
        project_id = data.project.id
        wipe_project_data(project_id)

        Logger.info("Inserting project data...")
        insert_projects([data.project])
        insert_components(data.components)
        # Versions before stories: stories reference versions via
        # first_version_id/current_version_id.
        insert_versions(data[:versions] || [])
        insert_stories(data[:stories] || [])

        reset_sequences()

        Logger.info("✓ Imported project #{data.project.name} (ID: #{project_id})")
      end)
    end
  end

  @doc """
  Exports exactly one project — its own row, components, stories, and the
  stories' versions. See `import_project/2`.
  """
  def export_project(project_id, output_path) do
    Logger.info("Exporting project #{project_id}...")

    project = Repo.get!(Project, project_id)

    data = %{
      project:
        Map.take(project, [
          :id,
          :name,
          :description,
          :module_name,
          :code_repo,
          :docs_repo,
          :client_api_url,
          :account_id,
          :status,
          :inserted_at,
          :updated_at
        ]),
      components: serialize_components(project_id),
      versions: serialize_versions(project_id),
      stories: serialize_stories(project_id)
    }

    json = Jason.encode!(data, pretty: true)
    File.write!(output_path, json)

    Logger.info("✓ Exported project #{project_id} to #{output_path}")
    Logger.info("  - #{length(data.components)} components")
    Logger.info("  - #{length(data.stories)} stories")
    Logger.info("  - #{length(data.versions)} versions")
  end

  # Serialization functions

  defp serialize_components(project_id) do
    Component
    |> where([c], c.project_id == ^project_id)
    |> Repo.all()
    |> Enum.map(fn component ->
      Map.take(component, [
        :id,
        :name,
        :type,
        :module_name,
        :description,
        :account_id,
        :project_id,
        :component_status,
        :parent_component_id,
        :inserted_at,
        :updated_at
      ])
    end)
  end

  defp serialize_stories(project_id) do
    Story
    |> where([s], s.project_id == ^project_id)
    |> Repo.all()
    |> Enum.map(fn story ->
      Map.take(story, [
        :id,
        :title,
        :description,
        :acceptance_criteria,
        :status,
        :locked_at,
        :lock_expires_at,
        :locked_by,
        :project_id,
        :component_id,
        :account_id,
        :first_version_id,
        :current_version_id,
        :inserted_at,
        :updated_at
      ])
    end)
  end

  defp serialize_versions(project_id) do
    story_ids =
      Story
      |> where([s], s.project_id == ^project_id)
      |> select([s], s.id)
      |> Repo.all()

    Version
    |> where([v], v.item_type == "Story" and v.item_id in ^story_ids)
    |> Repo.all()
    |> Enum.map(fn version ->
      Map.take(version, [
        :id,
        :event,
        :item_type,
        :item_id,
        :item_changes,
        :originator_id,
        :origin,
        :meta,
        :inserted_at
      ])
    end)
  end

  # Helper to parse datetime strings from JSON
  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _} -> dt
      {:error, _} -> nil
    end
  end

  # Wipe exactly this project's own rows — its stories (and their versions),
  # its components, and the project row itself. The account, its members and
  # users, and every other project it owns are untouched.
  defp wipe_project_data(project_id) do
    story_ids =
      from(st in Story, where: st.project_id == ^project_id, select: st.id) |> Repo.all()

    from(st in Story, where: st.project_id == ^project_id) |> Repo.delete_all()

    from(v in Version, where: v.item_type == "Story" and v.item_id in ^story_ids)
    |> Repo.delete_all()

    from(c in Component, where: c.project_id == ^project_id) |> Repo.delete_all()
    from(p in Project, where: p.id == ^project_id) |> Repo.delete_all()
  end

  # Insert functions - preserve IDs to maintain consistency across environments
  defp insert_projects(projects_data) do
    Enum.each(projects_data, fn project_data ->
      scope = %{active_account_id: project_data.account_id}

      %Project{id: project_data.id}
      |> Project.changeset(project_data, scope)
      |> Repo.insert!()
    end)
  end

  defp insert_components(components_data) do
    # Sort components so parents are inserted before children
    sorted_components = sort_components_by_dependency(components_data)

    Enum.each(sorted_components, fn component_data ->
      # Note: Using plain maps for active_account/active_project violates Scope typespec,
      # but Component.changeset.put_scope_associations only needs %{id: _} pattern match
      scope = %CodeMySpec.Users.Scope{
        user: nil,
        active_account_id: component_data.account_id,
        active_project_id: component_data.project_id
      }

      %Component{id: component_data.id}
      |> Component.changeset(component_data, scope)
      |> Repo.insert!()
    end)
  end

  # Sort components so parents are inserted before children
  defp sort_components_by_dependency(components) do
    # Topological sort: repeatedly insert components with no parent or whose parent is already inserted
    {sorted, _remaining} =
      Enum.reduce_while(1..length(components)//1, {[], components}, fn _iteration,
                                                                        {sorted, remaining} ->
        # Find components that can be inserted (no parent or parent already sorted)
        sorted_ids = MapSet.new(sorted, & &1.id)

        {insertable, still_waiting} =
          Enum.split_with(remaining, fn c ->
            is_nil(c.parent_component_id) or MapSet.member?(sorted_ids, c.parent_component_id)
          end)

        if insertable == [] do
          # No progress made - there's a circular dependency or missing parent
          {:halt, {sorted ++ remaining, []}}
        else
          {:cont, {sorted ++ insertable, still_waiting}}
        end
      end)

    sorted
  end

  defp insert_versions(versions_data) do
    Enum.each(versions_data, fn version_data ->
      inserted_at = parse_datetime(version_data.inserted_at)

      %Version{id: version_data.id}
      |> Ecto.Changeset.change(
        event: version_data.event,
        item_type: version_data.item_type,
        item_id: version_data.item_id,
        item_changes: version_data.item_changes,
        originator_id: version_data[:originator_id],
        origin: version_data[:origin],
        meta: version_data[:meta],
        inserted_at: inserted_at
      )
      |> Repo.insert!()
    end)
  end

  defp insert_stories(stories_data) do
    Enum.each(stories_data, fn story_data ->
      %Story{id: story_data.id}
      |> Story.changeset(story_data)
      |> Ecto.Changeset.put_change(:account_id, story_data.account_id)
      |> Ecto.Changeset.put_change(:first_version_id, story_data[:first_version_id])
      |> Ecto.Changeset.put_change(:current_version_id, story_data[:current_version_id])
      |> Repo.insert!()
    end)
  end

  # Reset all table sequences after manual ID insertion
  defp reset_sequences do
    # Only tables with an actual integer/serial :id. accounts and sessions
    # both moved to `@primary_key {:id, :binary_id, ...}` — components and
    # projects always were — so pg_get_serial_sequence has nothing to reset
    # for either, and MAX(id) on a uuid column fails outright rather than
    # returning something merely wrong.
    tables = ~w(versions stories)

    Enum.each(tables, fn table ->
      Repo.query!("""
        SELECT setval(pg_get_serial_sequence('#{table}', 'id'),
                      COALESCE((SELECT MAX(id) FROM #{table}), 1),
                      true)
      """)
    end)
  end
end
