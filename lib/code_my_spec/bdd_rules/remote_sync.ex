defmodule CodeMySpec.BddRules.RemoteSync do
  @moduledoc """
  Pulls BDD rules from the remote API and reconciles them into the local
  SQLite cache for the active project.

  Without this sync, server-side edits — most importantly **deletes** done
  via the web UI — never reach the local cache that the CLI agent reads
  through `BddRules.RemoteClient.list_rules_for_story/2`. The agent would
  keep seeing rules that no longer exist on the server.

  Mirrors `Personas.RemoteSync` and `Stories.RemoteSync` — same shape,
  same pattern. Project-scoped: each call replaces the local rule set for
  the project with the server's authoritative list, leaving rules from
  other projects untouched.
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.BddRules.RemoteClient
  alias CodeMySpec.BddRules.Rule
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @spec sync(Scope.t(), keyword()) :: :ok | {:error, term()}
  def sync(%Scope{active_project_id: project_id} = scope, opts \\ [])
      when is_binary(project_id) do
    with {:ok, token} <- OAuthClient.get_token(),
         client_opts = Keyword.put(opts, :token, token),
         rules <- RemoteClient.list_rules_for_project(scope, project_id, client_opts) do
      Logger.debug(
        "[BddRules.RemoteSync] Reconciling #{length(rules)} rules for project #{project_id}"
      )

      reconcile(rules, project_id)
      :ok
    end
  end

  defp reconcile(server_rules, project_id) do
    server_ids = MapSet.new(server_rules, & &1.id)
    local_ids = MapSet.new(local_rule_ids_for_project(project_id))

    to_delete = MapSet.difference(local_ids, server_ids)

    Enum.each(server_rules, &upsert_rule/1)
    delete_rules(to_delete)
    :ok
  end

  defp local_rule_ids_for_project(project_id) do
    from(r in Rule,
      where: r.project_id == ^project_id,
      select: r.id
    )
    |> Repo.all()
  end

  defp upsert_rule(%Rule{} = rule) do
    attrs = %{
      account_id: rule.account_id,
      project_id: rule.project_id,
      story_id: rule.story_id,
      statement: rule.statement
    }

    %Rule{id: rule.id}
    |> Rule.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
  end

  defp delete_rules(ids) do
    case MapSet.size(ids) do
      0 ->
        :ok

      _ ->
        id_list = MapSet.to_list(ids)

        from(r in Rule, where: r.id in ^id_list)
        |> Repo.delete_all()
    end
  end
end
