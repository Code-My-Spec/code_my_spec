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
    Repo.get_by(Issue, id: id, project_id: scope.active_project.id)
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

            {:ok, existing}

          _found ->
            {:ok, issue}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_status(%Issue{} = issue, status, resolution \\ nil) do
    issue
    |> Issue.status_changeset(%{status: status, resolution: resolution})
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
