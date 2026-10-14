defmodule CodeMySpec.Issues.IssuesRepository do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope
  alias Ecto.Changeset

  def list_issues(%Scope{} = scope) do
    Issue
    |> by_project(scope.active_project.id)
    |> ordered_by_severity()
    |> Repo.all()
  end

  @doc """
  Whether this project already has an unfinished issue with exactly this title.

  For the fault paths in `MainAgent`, which file by a title built from the
  fault and would otherwise bury the first report under copies of itself.

  Unfinished means anything but `:resolved`. `:dismissed` counts: the same
  fault recurring is still not worth acting on, and refiling would overrule
  the dismissal on every call. `:resolved` does not: a recurrence is a
  regression worth hearing about. A different fault has a different title and
  still files.
  """
  @spec open_issue_titled?(Scope.t(), String.t()) :: boolean()
  def open_issue_titled?(%Scope{active_project_id: project_id}, title)
      when is_binary(project_id) and is_binary(title) do
    Issue
    |> where([i], i.project_id == ^project_id and i.title == ^title)
    |> where([i], i.status != :resolved)
    |> Repo.exists?()
  end

  def open_issue_titled?(%Scope{}, _title), do: false

  def list_by_status(%Scope{} = scope, status) do
    Issue
    |> by_project(scope.active_project.id)
    |> by_status(status)
    |> ordered_by_severity()
    |> Repo.all()
  end

  @doc """
  The project's own issues at a status and severity — what `issues_triaged` and
  `issues_resolved` gate on, and what `AgentTasks.FixIssues` puts in front of an
  agent.

  Only `:app` issues gate: `:framework`, `:qa` and `:docs` findings are about
  the tooling around the work, and framework issues belong to the vendor. The
  vendor's own project also counts `:framework`, since there they are app
  issues. Issues on stories assigned to another copy are excluded.
  See knowledge/requirements_graph/checkers, "Issues".
  """
  def list_by_status_and_min_severity(%Scope{} = scope, status, min_severity) do
    Issue
    |> by_project(scope.active_project.id)
    |> by_status(status)
    |> by_min_severity(min_severity)
    |> exclude_framework_unless_vendor(scope)
    |> exclude_other_copies_stories(scope)
    |> ordered_by_severity()
    |> Repo.all()
  end

  @doc """
  What `issues_triaged` waits on: incoming issues at the threshold, and every
  incoming issue on a story at any severity.

  An incoming issue holds its story's QA whatever its severity
  (`story_issues_triaged`), so triage must reach a low one on a story.

  Every tenant scope counts, not only `:app`: triage is always satisfiable,
  since dismissing is an answer. Framework issues stay the vendor's.
  """
  def list_triageable(%Scope{} = scope, min_severity) do
    severities = Issue.severities_at_or_above(min_severity)

    Issue
    |> by_project(scope.active_project.id)
    |> by_status(:incoming)
    |> where([i], not is_nil(i.story_id) or i.severity in ^severities)
    |> triage_scopes(scope)
    |> exclude_other_copies_stories(scope)
    |> ordered_by_severity()
    |> Repo.all()
  end

  @doc """
  Incoming issues on each story, any severity, grouped by story — what
  `story_issues_triaged` reads for each story.
  """
  @spec incoming_by_story(Scope.t()) :: %{integer() => [Issue.t()]}
  def incoming_by_story(%Scope{} = scope) do
    Issue
    |> by_project(scope.active_project.id)
    |> by_status(:incoming)
    |> where([i], not is_nil(i.story_id))
    |> ordered_by_severity()
    |> Repo.all()
    |> Enum.group_by(& &1.story_id)
  end

  defp triage_scopes(query, scope) do
    case ensure_vendor(scope) do
      :ok -> query
      {:error, :not_the_vendor} -> where(query, [i], i.scope != :framework)
    end
  end

  # An issue about a story assigned to another working copy is that copy's work
  # (as `Validation.split_by_story_enforcement/3` treats spex findings). An
  # issue with no story, or an unassigned one, gates everywhere, so no finding
  # belongs to no one.
  defp exclude_other_copies_stories(query, %Scope{active_working_copy_id: here})
       when is_binary(here) do
    from(i in query,
      left_join: s in Story,
      on: s.id == i.story_id,
      where:
        is_nil(i.story_id) or is_nil(s.working_copy_id) or
          s.working_copy_id == type(^here, Ecto.UUID)
    )
  end

  defp exclude_other_copies_stories(query, %Scope{}), do: query

  defp exclude_framework_unless_vendor(query, scope) do
    case ensure_vendor(scope) do
      # The vendor's own project is where framework issues live, and there they
      # are app issues: `issues_resolved` should hold until they are fixed.
      :ok -> where(query, [i], i.scope in [:app, :framework])
      {:error, :not_the_vendor} -> where(query, [i], i.scope == :app)
    end
  end

  @doc "Resolved issues in a project, keyed by id — for callers holding only the id."
  def resolved_in_project(project_id) when is_binary(project_id) do
    from(i in Issue,
      where: i.project_id == ^project_id and i.status == :resolved,
      select: %{id: i.id, title: i.title}
    )
    |> Repo.all()
  end

  def list_by_story(%Scope{} = scope, story_id) do
    Issue
    |> by_project(scope.active_project.id)
    |> by_story(story_id)
    |> ordered_by_severity()
    |> Repo.all()
  end

  @doc """
  Attribute unattributed `:app` issues to a story. Returns the count updated.

  Deliberately narrow on both axes. `story_id is nil` so an explicit
  attribution is never overwritten, and `scope == :app` so only findings
  about the application under development can gate a story — a `:framework`,
  `:qa` or `:docs` finding raised during a story's QA pass is about the
  tooling around the work, not the work, and queues at the project level.
  """
  def attribute_to_story(%Scope{} = scope, issue_ids, story_id) do
    uuids = Enum.flat_map(issue_ids, &cast_uuid/1)

    if uuids == [] do
      0
    else
      {count, _} =
        Issue
        |> by_project(scope.active_project.id)
        |> where([i], i.id in ^uuids and is_nil(i.story_id) and i.scope == :app)
        |> Repo.update_all(set: [story_id: story_id])

      count
    end
  end

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> [uuid]
      :error -> []
    end
  end

  def get_issue!(%Scope{} = scope, id) do
    Repo.get_by!(Issue, id: id, project_id: scope.active_project.id)
  end

  def get_issue(%Scope{} = scope, id) do
    case fetch_issue(scope, id) do
      {:ok, issue} -> issue
      _ -> nil
    end
  end

  @doc """
  An issue by full id or by unique prefix (at least four hex characters), as
  `{:ok, issue}`, `:not_found` or `{:ambiguous, ids}`. Prefixes are what prose
  cites, and an ambiguous prefix must not read as a missing issue.

  Prefixes are matched in Elixir, not SQL: Postgres and the harness's SQLite
  disagree on what a `binary_id` is on the wire, and a fragment for one crashes
  the other.
  """
  @spec fetch_issue(Scope.t(), String.t()) ::
          {:ok, Issue.t()} | :not_found | {:ambiguous, [String.t()]}
  # Shorter than this is not a prefix anyone typed on purpose.
  @min_prefix 4

  def fetch_issue(%Scope{} = scope, id) when is_binary(id) do
    with {:ok, project} <- lookup_project(scope) do
      case lookup(project.id, id) do
        :not_found -> vendor_lookup(%{scope | active_project: project}, id)
        found -> found
      end
    end
  end

  # Background owners carry IDs rather than preloaded associations. Validate
  # the project against its account before either local or vendor lookup.
  defp lookup_project(scope) do
    project_id = scope.active_project_id || association_id(scope.active_project)
    account_id = scope.active_account_id || association_id(scope.active_account)

    with {:ok, project_id} <- Ecto.UUID.cast(project_id),
         {:ok, account_id} <- Ecto.UUID.cast(account_id),
         %Project{} = project <- Repo.get_by(Project, id: project_id, account_id: account_id) do
      {:ok, project}
    else
      _ -> :not_found
    end
  end

  defp association_id(%{id: id}), do: id
  defp association_id(_), do: nil

  # The vendor reaches a framework issue in any project, because that is where
  # framework issues live. Gated on who is asking, so every surface that
  # resolves an issue (get, update, accept, dismiss, resolve) follows. A tenant
  # gains nothing: `ensure_vendor/1` answers only for the configured project and
  # `only_framework/1` refuses other scopes.
  defp vendor_lookup(scope, id) do
    case ensure_vendor(scope) do
      :ok -> id |> lookup_anywhere() |> only_framework()
      {:error, :not_the_vendor} -> :not_found
    end
  end

  defp lookup_anywhere(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> exact_anywhere(uuid)
      :error -> by_prefix_anywhere(id)
    end
  end

  defp exact_anywhere(uuid) do
    case Repo.get(Issue, uuid) do
      nil -> :not_found
      issue -> {:ok, issue}
    end
  end

  defp by_prefix_anywhere(prefix) do
    normalized = String.downcase(prefix)

    if String.length(normalized) >= @min_prefix and normalized =~ ~r/\A[0-9a-f-]+\z/ do
      from(i in Issue, where: i.scope == :framework, select: i.id)
      |> Repo.all()
      |> Enum.filter(&String.starts_with?(String.downcase(to_string(&1)), normalized))
      |> resolve_anywhere_matches()
    else
      :not_found
    end
  end

  defp resolve_anywhere_matches([]), do: :not_found
  defp resolve_anywhere_matches([id]), do: exact_anywhere(id)
  defp resolve_anywhere_matches(ids), do: {:ambiguous, Enum.map(ids, &to_string/1)}

  # A non-framework issue in someone else's project is theirs, and is not
  # reachable this way whoever is asking.
  defp only_framework({:ok, %Issue{scope: :framework} = issue}), do: {:ok, issue}
  defp only_framework({:ok, _issue}), do: :not_found
  defp only_framework(other), do: other

  defp lookup(project_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> exact(project_id, uuid)
      :error -> by_prefix(project_id, id)
    end
  end

  defp exact(project_id, uuid) do
    case Repo.get_by(Issue, id: uuid, project_id: project_id) do
      nil -> :not_found
      issue -> {:ok, issue}
    end
  end

  defp by_prefix(project_id, prefix) do
    normalized = String.downcase(prefix)

    if String.length(normalized) >= @min_prefix and normalized =~ ~r/\A[0-9a-f-]+\z/ do
      from(i in Issue, where: i.project_id == ^project_id, select: i.id)
      |> Repo.all()
      |> Enum.filter(&String.starts_with?(String.downcase(to_string(&1)), normalized))
      |> resolve_prefix_matches(project_id)
    else
      :not_found
    end
  end

  defp resolve_prefix_matches([], _project_id), do: :not_found
  defp resolve_prefix_matches([id], project_id), do: exact(project_id, id)
  defp resolve_prefix_matches(ids, _project_id), do: {:ambiguous, Enum.map(ids, &to_string/1)}

  @doc """
  Every framework-scoped issue, across every project, for the vendor.

  Framework issues live in the project that filed them (no write crosses a
  project), and this is the single read that crosses to collect them: one
  guarded query rather than a write exception every read surface must match.

  Refuses unless the caller is the configured CodeMySpec project; an install
  with none configured has no vendor.
  """
  @spec list_framework_issues(Scope.t()) :: {:ok, [Issue.t()]} | {:error, :not_the_vendor}
  def list_framework_issues(%Scope{} = scope) do
    with :ok <- ensure_vendor(scope) do
      issues =
        Issue
        |> where([i], i.scope == :framework)
        |> ordered_by_severity()
        |> Repo.all()

      {:ok, issues}
    end
  end

  defp ensure_vendor(%Scope{active_project: %{id: id}}) do
    case Application.get_env(:code_my_spec, :code_my_spec_project_id) do
      configured when is_binary(configured) and configured != "" and configured == id -> :ok
      _ -> {:error, :not_the_vendor}
    end
  end

  defp ensure_vendor(_scope), do: {:error, :not_the_vendor}

  def create_issue(%Scope{} = scope, attrs) do
    scope
    |> scoped_changeset(attrs)
    |> Repo.insert()
  end

  # One builder for both writers, so a column cannot land on one path only.
  defp scoped_changeset(%Scope{} = scope, attrs) do
    project_id = resolve_project_id(scope)

    %Issue{}
    |> Issue.changeset(attrs)
    |> Changeset.put_change(:project_id, project_id)
    |> Changeset.put_change(:account_id, resolve_account_id(scope))
    # From the scope, never from the caller — an issue is raised *by* a working
    # copy, and letting a report name someone else's would make the field worse
    # than absent. Nil where there is no checkout, which is the web UI.
    |> Changeset.put_change(:working_copy_id, scope.active_working_copy_id)
    |> refuse_foreign_story(project_id)
  end

  # A story from another project is refused rather than linked: `project_id`
  # comes from the scope and `story_id` from the caller, and a row whose halves
  # name different projects is never seen by the owner and announces itself to
  # the wrong project's graph. Refused, not rehomed: an issue is filed where the
  # caller is.
  defp refuse_foreign_story(changeset, project_id) do
    case Changeset.get_change(changeset, :story_id) do
      nil ->
        changeset

      story_id ->
        if story_elsewhere?(story_id, project_id) do
          Changeset.add_error(
            changeset,
            :story_id,
            "belongs to another project — an issue is filed where the caller is, so " <>
              "linking it here would stamp this project's id on another project's story. " <>
              "File it from a session scoped to that project, or leave story_id out."
          )
        else
          changeset
        end
    end
  end

  # Only a story that exists in another project. A dangling id is allowed: the
  # link is loose by design, and issues can name a story before its row exists.
  defp story_elsewhere?(story_id, project_id) when is_binary(project_id) do
    Repo.exists?(
      from(s in "stories",
        where: s.id == ^story_id and s.project_id != type(^project_id, :binary_id)
      )
    )
  end

  # No project on the scope is a different refusal, and not this one's to make.
  defp story_elsewhere?(_story_id, _project_id), do: false

  def upsert_issue(%Scope{} = scope, attrs) do
    project_id = resolve_project_id(scope)

    changeset = scoped_changeset(scope, attrs)

    title =
      Changeset.get_change(changeset, :title) || Changeset.get_field(changeset, :title)

    story_id =
      Changeset.get_change(changeset, :story_id) ||
        Changeset.get_field(changeset, :story_id)

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
  `synced_from_server: true`. No caller in `lib` uses this, and nothing
  reads the flag.
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
    |> Changeset.put_change(:project_id, remote_issue.project_id)
    |> Changeset.put_change(:account_id, remote_issue.account_id)
    |> Changeset.put_change(:status, remote_issue.status)
    |> Changeset.put_change(:synced_from_server, true)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
  end

  @doc """
  Update non-status fields on an existing issue (severity, story_id,
  category, source_path). Goes through the generic `Issue.changeset`
  so the full validation set applies; status transitions stay on
  the `update_status` path with its tighter rules.
  """
  def update_attributes(%Issue{} = issue, attrs) do
    safe_attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.take(["severity", "story_id", "category", "source_path", "description"])

    issue
    |> Issue.changeset(safe_attrs)
    |> Repo.update()
  end

  @doc "Set or clear which copy's team this issue is assigned to, and whose turn it is next."
  def update_assignment(%Issue{} = issue, working_copy_id, awaiting_role) do
    issue
    |> Issue.assignment_changeset(%{
      assigned_working_copy_id: working_copy_id,
      awaiting_role: awaiting_role
    })
    |> Repo.update()
  end

  @doc "The accepted issue assigned to `working_copy_id`'s team, or nil."
  def assigned_to_copy(%Scope{active_project_id: project_id}, working_copy_id)
      when is_binary(working_copy_id) do
    Issue
    |> by_project(project_id)
    |> where([i], i.assigned_working_copy_id == ^working_copy_id and i.status == :accepted)
    # One waiting to be promoted first, then the oldest: a copy can hold
    # several, and an arbitrary pick sent a promote after the wrong one.
    |> order_by([i], desc: i.awaiting_role == :promote, asc: i.inserted_at, asc: i.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Record the commit an issue's fix landed at."
  def update_landed_commit(%Issue{} = issue, commit) do
    issue
    |> Issue.landed_changeset(commit)
    |> Repo.update()
  end

  @doc "Stamps the commit `Promotion.certify/3` passed the issue's fix at."
  def update_qa_ready_commit(%Issue{} = issue, commit, at) do
    issue
    |> Issue.qa_ready_changeset(commit, at)
    |> Repo.update()
  end

  @doc "Flip whose turn it is on an already-assigned issue."
  def update_awaiting_role(%Issue{} = issue, role) do
    issue
    |> Issue.assignment_changeset(%{awaiting_role: role})
    |> Repo.update()
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
      {:error, Changeset.change(issue) |> Changeset.add_error(:id, "does not exist")}
  end

  @doc "Most recent inherited fix submission per story, using its immutable submission timestamp."
  def latest_story_submissions(project_id, story_ids) when is_list(story_ids) do
    from(i in Issue,
      where: i.project_id == ^project_id and i.story_id in ^story_ids,
      where: is_nil(i.assigned_working_copy_id) and not is_nil(i.story_submitted_at),
      where: i.status in [:accepted, :resolved],
      select: {i.story_id, i.id, i.story_submitted_at}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_story_id, id, at} -> {id, at} end)
    |> Map.new(fn {story_id, rows} -> {story_id, Enum.max_by(rows, &elem(&1, 1), DateTime)} end)
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
