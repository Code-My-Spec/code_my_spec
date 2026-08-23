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

  def list_by_status_and_min_severity(%Scope{} = scope, status, min_severity) do
    Issue
    |> by_project(scope.active_project.id)
    |> by_status(status)
    |> by_min_severity(min_severity)
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

  def list_by_story_status_and_min_severity(%Scope{} = scope, story_id, status, min_severity) do
    Issue
    |> by_project(scope.active_project.id)
    |> by_story(story_id)
    |> by_status(status)
    |> by_min_severity(min_severity)
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
  An issue by full id or by unique prefix, saying which of the three answers it is.

  `98fa6656`. This took only a full UUID and answered anything else with `nil`,
  which every caller renders as "Issue not found." That message is a claim about
  the issue when the truth is a claim about the argument, and the two are not
  interchangeable: an agent told an id does not exist has no reason to doubt it.

  The prefix is the input this will keep being given. Nothing in the codebase
  cites a full UUID — commit messages, code comments, spec files and issue
  bodies all use the 8-character prefix, because that is what fits in prose. So
  the common path to this function is copying a prefix out of a comment, and
  that path always failed.

  Measured cost: a correct citation was deleted from `justfile` on the strength
  of a "not found" for `f58acb37`, which exists and was exactly the right
  reference. The repair — removing the reference — looks like diligence, which
  is what makes it worse than an error.

  ## Three answers, not two

  `{:ambiguous, ids}` exists because collapsing it into `:not_found` rebuilds
  the original defect one case along: the caller would again be told something
  false about the issue rather than something true about the argument.

  ## Filtering in Elixir rather than in SQL

  `CodeMySpec.Repo` runs on Postgres normally and on SQLite in `cli_demo`, and
  the two disagree about what a `binary_id` is on the wire — Postgres stores a
  `uuid` needing `::text` to pattern-match, SQLite a string that matches
  directly. A fragment for either crashes the other, which is `61351c19`
  exactly. Selecting ids and filtering here is portable and costs one small
  query on a table with hundreds of rows, not millions.
  """
  @spec fetch_issue(Scope.t(), String.t()) ::
          {:ok, Issue.t()} | :not_found | {:ambiguous, [String.t()]}
  # Four hex characters is roughly 65k values, so a collision across a few
  # hundred issues is possible rather than fanciful — which is what
  # `{:ambiguous, …}` is for. Shorter than that is not a prefix anyone typed on
  # purpose, and matching it would turn a typo into a wrong issue.
  @min_prefix 4

  def fetch_issue(%Scope{} = scope, id) when is_binary(id) do
    case lookup(scope.active_project.id, id) do
      :not_found -> vendor_lookup(scope, id)
      found -> found
    end
  end

  # The vendor reaches a framework issue in any project, because that is where
  # framework issues live.
  #
  # Gated on who is asking rather than on an option the call site passes, which
  # is what makes it right for every surface at once. `get_issue`,
  # `update_issue`, `accept_issue`, `dismiss_issue` and `resolve_issue` all
  # resolve an issue this way, and the vendor needs all five: seeing a backlog
  # it cannot work is half a feature. The first cut of this widened only reading
  # — the vendor could list the framework queue and then not dismiss anything in
  # it, which is how this was found.
  #
  # A tenant gains nothing. `ensure_vendor/1` answers only for the configured
  # CodeMySpec project, and `only_framework/1` refuses anything else in the
  # project it lands in, so this cannot become a way to read a stranger's app
  # issues.
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

  Framework issues are friction with CodeMySpec itself, and they are filed by
  agents working in other people's projects. They live where they were filed —
  one invariant, no exception on any write — and this is the single place that
  crosses a project boundary to collect them.

  The exception is here rather than on the write for two reasons. It is one
  guarded query instead of a relaxation that every read surface has to match:
  when the write crossed, `get_issue` and `update_issue` did not follow, so an
  agent could file a framework issue and never read it back or correct it, and
  three agents' Vibium evidence arrived as four separate reports. And it is the
  milder direction — a vendor reading reports filed *to* the vendor, by someone
  who filed them precisely so the vendor would read them, rather than a tenant
  writing into a project it cannot see.

  Refuses unless the caller is the configured CodeMySpec project. An install
  that has not been told which project that is has no vendor, so nobody may
  read across.
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

  # Both writers build the same changeset, and they diverged: `upsert_issue/2`
  # set the project and the account and never the harness, so anything arriving
  # through it was stored with no working copy no matter what the scope knew.
  #
  # Invisible in the way that costs most — the filing agent usually writes the
  # working copy into the description, so the issue *reads* as attributed while
  # the column is null, and two checkouts of one project file findings that look
  # identical and are about different trees.
  #
  # One builder, so the next column added cannot land on one path only.
  defp scoped_changeset(%Scope{} = scope, attrs) do
    %Issue{}
    |> Issue.changeset(attrs)
    |> Ecto.Changeset.put_change(:project_id, resolve_project_id(scope))
    |> Ecto.Changeset.put_change(:account_id, resolve_account_id(scope))
    # From the scope, never from the caller — an issue is raised *by* a working
    # copy, and letting a report name someone else's would make the field worse
    # than absent. Nil where there is no checkout, which is the web UI.
    |> Ecto.Changeset.put_change(:working_copy_id, scope.active_working_copy_id)
  end

  def upsert_issue(%Scope{} = scope, attrs) do
    project_id = resolve_project_id(scope)

    changeset = scoped_changeset(scope, attrs)

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
