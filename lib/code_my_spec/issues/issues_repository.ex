defmodule CodeMySpec.Issues.IssuesRepository do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  def list_issues(%Scope{} = scope) do
    Issue
    |> by_project(scope.active_project.id)
    |> ordered_by_severity()
    |> Repo.all()
  end

  def list_by_status(%Scope{} = scope, status) do
    Issue
    |> by_project(scope.active_project.id)
    |> by_status(status)
    |> ordered_by_severity()
    |> Repo.all()
  end

  def list_by_story(%Scope{} = scope, story_id) do
    Issue
    |> by_project(scope.active_project.id)
    |> by_story(story_id)
    |> ordered_by_severity()
    |> Repo.all()
  end

  def get_issue!(%Scope{} = scope, id) do
    Repo.get_by!(Issue, id: id, project_id: scope.active_project.id)
  end

  def get_issue(%Scope{} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Issue, id: uuid, project_id: scope.active_project.id)
      :error -> nil
    end
  end

  def create_issue(%Scope{} = scope, attrs) do
    project_id = resolve_project_id(scope)
    account_id = resolve_account_id(scope)
    %Issue{}
    |> Issue.changeset(attrs)
    |> Ecto.Changeset.put_change(:project_id, project_id)
    |> Ecto.Changeset.put_change(:account_id, account_id)
    |> Repo.insert()
  end

  def upsert_issue(%Scope{} = scope, attrs) do
    project_id = resolve_project_id(scope)
    account_id = resolve_account_id(scope)
    changeset =
      %Issue{}
      |> Issue.changeset(attrs)
      |> Ecto.Changeset.put_change(:project_id, project_id)
      |> Ecto.Changeset.put_change(:account_id, account_id)

    title =
      Ecto.Changeset.get_change(changeset, :title) || Ecto.Changeset.get_field(changeset, :title)

    story_id =
      Ecto.Changeset.get_change(changeset, :story_id) ||
        Ecto.Changeset.get_field(changeset, :story_id)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:title, :story_id, :project_id]
         ) do
      {:ok, issue} ->
        # With binary_id, id is always pre-generated. Check DB to detect conflict.
        case Repo.get(Issue, issue.id) do
          nil ->
            # Row not actually inserted (conflict) — fetch existing
            existing =
              Repo.get_by!(Issue, title: title, story_id: story_id, project_id: project_id)

            {:ok, existing, :existing}

          _found ->
            {:ok, issue, :created}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Upserts an issue pulled from the remote server.

  Inserts by primary key (the server's UUID is authoritative) and
  replaces all writable fields on conflict so a subsequent pull
  rewrites local rows with the server's current view. Sets
  `synced_from_server: true` so dispositions on this issue route
  back to the server.
  """
  def upsert_from_server(%Scope{} = _scope, %Issue{} = remote_issue) do
    attrs = %{
      title: remote_issue.title,
      severity: remote_issue.severity,
      scope: remote_issue.scope,
      description: remote_issue.description,
      status: remote_issue.status,
      category: remote_issue.category,
      resolution: remote_issue.resolution,
      source: remote_issue.source,
      story_id: remote_issue.story_id,
      source_path: remote_issue.source_path
    }

    %Issue{id: remote_issue.id}
    |> Issue.changeset(attrs)
    |> Ecto.Changeset.put_change(:project_id, remote_issue.project_id)
    |> Ecto.Changeset.put_change(:account_id, remote_issue.account_id)
    |> Ecto.Changeset.put_change(:status, remote_issue.status)
    |> Ecto.Changeset.put_change(:synced_from_server, true)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
  end

  def update_status(%Issue{} = issue, status, resolution \\ nil, opts \\ []) do
    attrs = %{status: status, resolution: resolution}

    attrs =
      case Keyword.get(opts, :story_id) do
        nil -> attrs
        story_id -> Map.put(attrs, :story_id, story_id)
      end

    attrs =
      case Keyword.get(opts, :category) do
        nil -> attrs
        category -> Map.put(attrs, :category, category)
      end

    issue
    |> Issue.status_changeset(attrs)
    |> Repo.update()
  end

  def count_by_status_and_min_severity(%Scope{} = scope, status, min_severity) do
    severities = Issue.severities_at_or_above(min_severity)

    Issue
    |> by_project(scope.active_project.id)
    |> by_status(status)
    |> where([i], i.severity in ^severities)
    |> Repo.aggregate(:count)
  end

  def delete_issue(%Issue{} = issue) do
    Repo.delete(issue)
  rescue
    Ecto.StaleEntryError ->
      {:error, Ecto.Changeset.change(issue) |> Ecto.Changeset.add_error(:id, "does not exist")}
  end

  def list_filtered(%Scope{} = scope, filters) when is_map(filters) do
    Issue
    |> by_project(scope.active_project.id)
    |> maybe_filter(:status, filters)
    |> maybe_filter(:severity, filters)
    |> maybe_filter(:story_id, filters)
    |> maybe_filter(:scope, filters)
    |> ordered_by_severity()
    |> Repo.all()
  end

  # Query composables

  def by_project(query \\ Issue, project_id) do
    from(i in query, where: i.project_id == ^project_id)
  end

  def by_status(query \\ Issue, status) do
    from(i in query, where: i.status == ^status)
  end

  def by_story(query \\ Issue, story_id) do
    from(i in query, where: i.story_id == ^story_id)
  end

  def by_severity(query \\ Issue, severity) do
    from(i in query, where: i.severity == ^severity)
  end

  def by_min_severity(query \\ Issue, min_severity) do
    severities = Issue.severities_at_or_above(min_severity)
    from(i in query, where: i.severity in ^severities)
  end

  def by_scope(query \\ Issue, scope) do
    from(i in query, where: i.scope == ^scope)
  end

  defp maybe_filter(query, :status, %{status: status}) when not is_nil(status),
    do: by_status(query, status)

  defp maybe_filter(query, :severity, %{severity: severity}) when not is_nil(severity),
    do: by_severity(query, severity)

  defp maybe_filter(query, :story_id, %{story_id: story_id}) when not is_nil(story_id),
    do: by_story(query, story_id)

  defp maybe_filter(query, :scope, %{scope: scope}) when not is_nil(scope),
    do: by_scope(query, scope)

  defp maybe_filter(query, _, _), do: query

  defp resolve_project_id(%Scope{active_project: %Project{id: id}}), do: id
  defp resolve_project_id(%Scope{active_project_id: id}) when not is_nil(id), do: id

  defp resolve_account_id(%Scope{active_account: %Account{id: id}}), do: id
  defp resolve_account_id(%Scope{active_account_id: id}) when not is_nil(id), do: id

  def ordered_by_severity(query \\ Issue) do
    order_by(query, [i],
      asc:
        fragment(
          "CASE ? WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 WHEN 'info' THEN 4 ELSE 99 END",
          i.severity
        ),
      desc: i.inserted_at
    )
  end
end
