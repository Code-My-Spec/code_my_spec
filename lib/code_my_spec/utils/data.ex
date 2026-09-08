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
  create one. `import_project/2` checks for it and says so, because the raw
  foreign key error names a constraint rather than the thing to fix.

  ## What an import can and cannot put back

  The export carries the project row, its components, its stories and those
  stories' versions. The wipe deletes the project row, and almost every table
  referencing `projects` cascades from it — measured, thirty-one of thirty-two.
  So a wipe reaches epics, issues, conversations, agents, working copies,
  requirement graphs, personas, criteria, BDD rules, secrets and provisioning
  records, and the file has nothing to restore any of them with.

  Nearly ran for real: dev's MarketMySpec (no stories) was about to be imported
  over production's (27 stories, 180 criteria, 17 issues). Two accidents stopped
  it — the ids differed so the wipe matched nothing, and the source account was
  absent so the insert would have failed. Aligning the ids, the obvious response
  to "the import did nothing", is what would have armed it.

  So `import_project/2` counts what it would destroy and refuses. The list comes
  from the database's own foreign keys rather than a list kept here, because a
  list kept here is exactly what drifted: every table added since would be
  missing from it, and missing means silently destroyed. `force: true` proceeds
  anyway, for a caller that has read the refusal and means it.
  """

  require Logger

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias Ecto.Changeset
  alias PaperTrail.Version

  import Ecto.Query

  @doc """
  Imports exactly one project's data — the project row, its components, and
  its stories/versions. Never touches the account, its members, its users, or
  any other project under that account.
  """
  def import_project(file_path, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    force = Keyword.get(opts, :force, false)

    Logger.info("Importing project from #{file_path}...")

    json = File.read!(file_path)
    data = Jason.decode!(json, keys: :atoms)
    project_id = data.project.id

    if dry_run do
      Logger.info("[DRY RUN] Would import:")
      Logger.info("  - Project: #{data.project.name}")
      Logger.info("  - #{length(data.components)} components")
      Logger.info("  - #{length(data.stories || [])} stories")
      Logger.info("  - #{length(data.versions || [])} versions")

      # Reported rather than refused: a dry run changes nothing, and this is
      # the place someone is actually looking before they commit to it.
      log_hazards(data.project.account_id, project_id)
    else
      with :ok <- account_present(data.project.account_id, data.project.name),
           :ok <- nothing_unrestorable(project_id, force) do
        import_transaction(data, project_id)
      end
    end
  end

  defp import_transaction(data, project_id) do
    Repo.transaction(fn ->
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

  # What the export file can actually put back after the wipe.
  #
  # `versions` is absent deliberately: PaperTrail keys on item_type/item_id and
  # holds no project_id, so it is not a cascading child and never appears in the
  # list this is subtracted from.
  @restorable ~w(components stories)

  # Everything the wipe destroys that the file cannot restore.
  #
  # Read out of `pg_constraint` rather than listed here. A list here is the bug:
  # it was accurate when written, the schema kept growing, and a table missing
  # from it is destroyed in silence rather than refused out loud. The database
  # already knows which foreign keys cascade, so ask it.
  defp unrestorable_children(project_id) do
    cascading_children()
    |> Enum.reject(fn {table, _column} -> table in @restorable end)
    |> Enum.map(fn {table, column} ->
      {table, count_children(table, column, project_id)}
    end)
    |> Enum.reject(fn {_table, count} -> count == 0 end)
    |> Enum.sort_by(fn {table, count} -> {-count, table} end)
  end

  defp count_children(table, column, project_id) do
    field = String.to_atom(column)

    Repo.aggregate(
      from(x in table, where: field(x, ^field) == type(^project_id, Ecto.UUID)),
      :count
    )
  end

  defp cascading_children do
    %{rows: rows} =
      Repo.query!("""
      select c.conrelid::regclass::text, a.attname
      from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
      where c.confrelid = 'projects'::regclass
        and c.contype = 'f'
        and c.confdeltype = 'c'
      """)

    Enum.map(rows, fn [table, column] -> {table, column} end)
  end

  defp nothing_unrestorable(_project_id, true), do: :ok

  defp nothing_unrestorable(project_id, false) do
    case unrestorable_children(project_id) do
      [] -> :ok
      losses -> {:error, {:would_destroy, project_id, losses}}
    end
  end

  # The insert fails on this anyway. It fails as a foreign key violation naming
  # a constraint, which says nothing about which account is missing from which
  # environment — and by then the wipe has already run inside the same
  # transaction, so the rollback is what saves the data rather than the check.
  defp account_present(account_id, project_name) do
    if Repo.exists?(from a in "accounts", where: a.id == type(^account_id, Ecto.UUID)) do
      :ok
    else
      {:error, {:missing_account, account_id, project_name}}
    end
  end

  defp log_hazards(account_id, project_id) do
    case account_present(account_id, nil) do
      :ok -> :ok
      {:error, _} -> Logger.warning("[DRY RUN] destination account #{account_id} does not exist")
    end

    case unrestorable_children(project_id) do
      [] ->
        :ok

      losses ->
        Logger.warning("[DRY RUN] this import would destroy, with nothing to restore them:")
        Enum.each(losses, fn {table, count} -> Logger.warning("  - #{count} #{table}") end)
    end
  end

  @doc """
  A refusal from `import_project/2`, as something a person can act on.

  Separate from the tuple because the tuple is for a caller that wants to
  branch and this is for the human the shell script is standing in front of.
  """
  def explain({:missing_account, account_id, project_name}) do
    """
    Refusing to import #{project_name || "this project"}.

    Its account #{account_id} does not exist in the destination database. A
    project cannot be created under an account that is not there, and importing
    one does not create it.

    Either the export came from an environment whose accounts were never synced,
    or the destination already holds this project under a different account. It
    is worth checking for the latter by name before creating anything: importing
    against a fresh account id makes a second copy of the project rather than
    updating the one already there.
    """
  end

  def explain({:would_destroy, project_id, losses}) do
    lines = Enum.map_join(losses, "\n", fn {table, count} -> "      #{count} #{table}" end)

    """
    Refusing to import over project #{project_id}.

    The wipe deletes the project row, and these rows cascade away with it:

    #{lines}

    The export file carries the project, its components, its stories and their
    versions — and nothing else. Everything above would be destroyed with no way
    to put it back.

    If the destination is the one holding the real data, the import is pointed
    the wrong way round. If you have read this list and mean it, pass
    `force: true`.
    """
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
      |> Changeset.change(
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
      |> Changeset.put_change(:account_id, story_data.account_id)
      |> Changeset.put_change(:first_version_id, story_data[:first_version_id])
      |> Changeset.put_change(:current_version_id, story_data[:current_version_id])
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
