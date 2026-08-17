defmodule CodeMySpec.Utils.Data do
  @moduledoc """
  Data import/export utilities for syncing data between environments.
  Used by both Mix tasks and release commands.
  """

  require Logger

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Accounts.Member
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.User
  alias PaperTrail.Version

  import Ecto.Query

  def import_account(file_path, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    Logger.info("Importing account from #{file_path}...")

    json = File.read!(file_path)
    data = Jason.decode!(json, keys: :atoms)

    if dry_run do
      Logger.info("[DRY RUN] Would import:")
      Logger.info("  - Account: #{data.account.name}")
      Logger.info("  - #{length(data.users)} users")
      Logger.info("  - #{length(data.projects)} projects")
      Logger.info("  - #{length(data.components)} components")
      Logger.info("  - #{length(data.stories || [])} stories")
      Logger.info("  - #{length(data.versions || [])} versions")
      Logger.info("  - #{length(data.sessions)} sessions")
    else
      Repo.transaction(fn ->
        account_id = Map.get(data.account, :id)
        maybe_wipe_account_data(account_id)

        # Insert fresh data in dependency order
        Logger.info("Inserting account data...")
        inserted_account = insert_account(data.account)
        account_id = inserted_account.id
        insert_users(data.users)
        insert_members(data.members)
        insert_projects(data.projects)
        insert_components(data.components)

        # Insert versions before stories (stories reference versions via first_version_id/current_version_id)
        insert_versions(data[:versions] || [])
        insert_stories(data[:stories] || [])
        # Skip sessions - they're environment-specific and complex to sync
        # insert_sessions(data.sessions)
        Logger.info("Skipped #{length(data.sessions || [])} sessions (environment-specific)")

        # Reset sequences after manually setting IDs to prevent conflicts
        reset_sequences()

        Logger.info("✓ Imported account #{data.account.name} (ID: #{account_id})")
      end)
    end
  end

  # Reset all table sequences after manual ID insertion
  defp reset_sequences do
    # Exclude tables that use UUID primary keys (no sequence): components, projects
    tables = ~w(accounts users members versions stories sessions)

    Enum.each(tables, fn table ->
      Repo.query!("""
        SELECT setval(pg_get_serial_sequence('#{table}', 'id'),
                      COALESCE((SELECT MAX(id) FROM #{table}), 1),
                      true)
      """)
    end)
  end

  def export_account(account_id, output_path) do
    Logger.info("Exporting account #{account_id}...")

    account = Repo.get!(Account, account_id) |> Repo.preload([:members, :users])

    data = %{
      account: serialize_account(account),
      users: serialize_users(account),
      members: serialize_members(account),
      projects: serialize_projects(account_id),
      components: serialize_components(account_id),
      versions: serialize_versions(account_id),
      stories: serialize_stories(account_id),
      sessions: serialize_sessions(account_id)
    }

    json = Jason.encode!(data, pretty: true)
    File.write!(output_path, json)

    Logger.info("✓ Exported account #{account_id} to #{output_path}")
    Logger.info("  - #{length(data.users)} users")
    Logger.info("  - #{length(data.projects)} projects")
    Logger.info("  - #{length(data.components)} components")
    Logger.info("  - #{length(data.stories)} stories")
    Logger.info("  - #{length(data.versions)} versions")
    Logger.info("  - #{length(data.sessions)} sessions")
  end

  # Serialization functions

  defp serialize_account(account) do
    Map.take(account, [:id, :name, :slug, :type])
  end

  defp serialize_users(account) do
    Enum.map(account.users, fn user ->
      Map.take(user, [:id, :email, :hashed_password, :confirmed_at, :inserted_at, :updated_at])
    end)
  end

  defp serialize_members(account) do
    Enum.map(account.members, fn member ->
      Map.take(member, [:id, :user_id, :account_id, :role, :inserted_at, :updated_at])
    end)
  end

  defp serialize_projects(account_id) do
    Project
    |> where([p], p.account_id == ^account_id)
    |> Repo.all()
    |> Enum.map(fn project ->
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
      ])
    end)
  end

  defp serialize_components(account_id) do
    Component
    |> where([c], c.account_id == ^account_id)
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

  defp serialize_stories(account_id) do
    Story
    |> where([s], s.account_id == ^account_id)
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

  defp serialize_versions(account_id) do
    # Get all story IDs for this account
    story_ids =
      Story
      |> where([s], s.account_id == ^account_id)
      |> select([s], s.id)
      |> Repo.all()

    # Get all versions for those stories
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

  defp serialize_sessions(account_id) do
    Session
    |> where([s], s.account_id == ^account_id)
    |> Repo.all()
    |> Enum.map(fn session ->
      # Convert session to map, ensuring types are serialized as strings
      session_map =
        Map.take(session, [
          :id,
          :type,
          :status,
          :state,
          :account_id,
          :project_id,
          :component_id,
          :user_id,
          :session_id,
          :inserted_at,
          :updated_at
        ])

      # Convert atom/enum types to strings for JSON serialization
      session_map
      |> Map.update(:type, nil, &to_string/1)
      |> Map.update(:status, nil, &to_string/1)
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

  defp maybe_wipe_account_data(nil) do
    Logger.info("Creating new account...")
  end

  defp maybe_wipe_account_data(account_id) do
    Logger.info("Wiping existing data for account #{account_id}...")
    wipe_account_data(account_id)
  end

  # Wipe all data for an account
  defp wipe_account_data(account_id) do
    # Get user IDs for this account before deleting anything
    user_ids =
      from(m in Member, where: m.account_id == ^account_id, select: m.user_id) |> Repo.all()

    # Get all account IDs for these users (including personal accounts)
    all_account_ids =
      from(m in Member, where: m.user_id in ^user_ids, select: m.account_id, distinct: true)
      |> Repo.all()

    # Get story IDs for ALL these accounts (not just the target account)
    story_ids =
      from(st in Story, where: st.account_id in ^all_account_ids, select: st.id) |> Repo.all()

    # Delete in reverse dependency order for ALL accounts owned by these users
    from(s in Session, where: s.account_id in ^all_account_ids) |> Repo.delete_all()
    from(st in Story, where: st.account_id in ^all_account_ids) |> Repo.delete_all()

    from(v in Version, where: v.item_type == "Story" and v.item_id in ^story_ids)
    |> Repo.delete_all()

    from(c in Component, where: c.account_id in ^all_account_ids) |> Repo.delete_all()
    from(p in Project, where: p.account_id in ^all_account_ids) |> Repo.delete_all()
    from(m in Member, where: m.user_id in ^user_ids) |> Repo.delete_all()
    from(u in User, where: u.id in ^user_ids) |> Repo.delete_all()
    from(a in Account, where: a.id in ^all_account_ids) |> Repo.delete_all()
  end

  # Insert functions - preserve IDs to maintain consistency across environments
  # This is important because account_id=4 should be the same account in all environments
  defp insert_account(account_data) do
    account_struct =
      if Map.has_key?(account_data, :id) and not is_nil(account_data.id) do
        %Account{id: account_data.id}
      else
        %Account{}
      end

    account_struct
    |> Account.changeset(account_data)
    |> Repo.insert!()
  end

  defp insert_users(users_data) do
    Enum.each(users_data, fn user_data ->
      confirmed_at = parse_datetime(user_data[:confirmed_at])

      %User{id: user_data.id}
      |> User.email_changeset(user_data, validate_unique: false)
      |> Ecto.Changeset.put_change(:hashed_password, user_data.hashed_password)
      |> Ecto.Changeset.put_change(:confirmed_at, confirmed_at)
      |> Repo.insert!()
    end)
  end

  defp insert_members(members_data) do
    Enum.each(members_data, fn member_data ->
      %Member{id: member_data.id}
      |> Member.changeset(member_data)
      |> Repo.insert!()
    end)
  end

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

  # defp insert_sessions(sessions_data) do
  #   Enum.each(sessions_data, fn session_data ->
  #     scope = %CodeMySpec.Users.Scope{
  #       user: %{id: session_data.user_id},
  #       active_account_id: session_data.account_id,
  #       active_account: %{id: session_data.account_id},
  #       active_project_id: session_data.project_id,
  #       active_project: %{id: session_data.project_id}
  #     }

  #     %Session{id: session_data.id}
  #     |> Session.changeset(session_data, scope)
  #     |> Repo.insert!()
  #   end)
  # end
end
