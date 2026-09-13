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

  For the fault paths in `MainAgent`, which file by a title built from the fault
  itself. A machine-wide tool fault or a restart that changed nothing persists
  while somebody works out what to do about it, and the cadence keeps calling
  the thing that reports it — so without this the first, real issue is buried
  under copies of itself. Measured: six identical issues from one QA measurement,
  and two from a single `check_machinery` followed by one `restart_agent`
  (`57ba014e`).

  Open means `:incoming` or `:accepted` — not yet dealt with. A `:dismissed` or
  `:resolved` issue is finished with, so a fault recurring after that is news
  and files again.
  """
  @spec open_issue_titled?(Scope.t(), String.t()) :: boolean()
  def open_issue_titled?(%Scope{active_project_id: project_id}, title)
      when is_binary(project_id) and is_binary(title) do
    Issue
    |> where([i], i.project_id == ^project_id and i.title == ^title)
    |> where([i], i.status in [:incoming, :accepted])
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

  Only `:app` issues gate, because only `:app` issues are about the application
  under development. `attribute_to_story/3` already says this one level down —
  a `:framework`, `:qa` or `:docs` finding is "about the tooling around the
  work, not the work" — and the same sentence decides the project gate.

  Framework issues additionally belong to somebody else. `vendor_lookup/2`
  states it: "the vendor reaches a framework issue in any project, because that
  is where framework issues live", and `only_framework/1` refuses a tenant the
  same rows. Counting them asked a tenant to clear a queue it is not allowed to
  touch, and a gate whose passing state depends on another repository is a
  wall.

  Measured on Broken Oaths 2026-09-08: 22 of the 33 issues holding
  `issues_resolved` were `:framework` — `tool_docs ignores requested tool
  names`, `Task tools unavailable without session owner`, `list_tasks cannot
  identify the active agent`. A coding agent held that task for two hours and
  resolved none of them, because none of them are in its repository. One of the
  22 is a report of this defect, filed 09-06.

  Excluding `:framework` alone left two, and they made the case for the rest:
  `run_browser_script returns stale tool_docs catalog` and `QA session loop
  repeats identical nudge every turn` — both CodeMySpec's own defects, filed
  under `:qa` because that is the pass they were found on. The agent read all
  34, checked the two that might have touched its code, and reported back that
  neither did. It was right, and it was still held.

  The vendor's own project keeps them: there, framework issues *are* app issues,
  and `issues_resolved` should hold until they are fixed.

  `attribute_to_story/3` already declines to attach a framework finding to a
  story, on the argument that it is "about the tooling around the work, not the
  work". This is that argument one level up: not the work, and not the project's
  gate either.
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

  # An issue about a story assigned to another working copy is that copy's work.
  #
  # The same rule `Validation.split_by_story_enforcement/3` applies to spex
  # findings, and it belongs here for the same reason: a gate whose passing
  # state depends on work outside the gated unit is a wall.
  #
  # Measured on Broken Oaths 2026-09-09: the coding agent on the war-epic copy
  # could not close `issues_resolved` because of one issue on story 947, which
  # belongs to "Diplomacy and Alliances" and lives on the main checkout. John
  # had already told it to leave that story alone — "park it, shouldn't be in
  # this copy" — and the agent said so plainly: the gap "stays open by
  # deliberate user decision, not by anything left for me to do." It was right,
  # and it was still held.
  #
  # An issue with no story, or one whose story is unassigned, gates everywhere.
  # Nobody else owns it, and dropping it would let a finding belong to no one.
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

  # A story from another project is refused rather than linked.
  #
  # `project_id` comes from the scope and `story_id` comes from the caller, and
  # nothing checked they agreed. So an agent filing against a story it could see
  # but did not own got an issue stamped with *its own* project and the other
  # project's story — a row whose two halves describe different projects, and
  # which the owning project never sees.
  #
  # Silent, and worse than a refusal in three ways. The filer believes the
  # report landed. The project it was about never receives it. And
  # `Issues.broadcast/2` calls `GraphInputs.changed/1` with the caller's scope,
  # so the graph signal goes to the wrong project's watcher too — a write that
  # announces itself to somebody else.
  #
  # Measured 2026-09-11 by a QA agent that filed five issues against another
  # project's stories and found all five stamped with its own `project_id`
  # (a7d8e008). It had earlier reported that `create_issue` "works
  # cross-project, unlike start_agent"; it does not refuse, which is not the
  # same thing.
  #
  # Refusing rather than honouring the story's project on purpose. "Every scope
  # files where the caller is" is this tool's documented design and the read
  # surfaces are built on it — `7c44ed8d` tried writing across the tenancy
  # boundary and had to be reverted because `get_issue` and `update_issue` had
  # no matching exception, so the filer could never read its own report back.
  # The bug is not that it files locally; it is that it accepted a story saying
  # otherwise.
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

  # Only a story that exists *somewhere else*.
  #
  # Not "a story not in this project" — that also catches an id matching no
  # story at all, and those are routine here: issues are filed against story
  # numbers before a sync has created the row, and the repository's own tests
  # use ids like 1 and 99 precisely because the link is loose by design.
  #
  # The harm being prevented is narrower and specific: an issue stamped with one
  # project and linked to a story that demonstrably belongs to another. A
  # dangling id is a different problem and refusing it here would be this guard
  # inventing a constraint nobody asked for.
  defp story_elsewhere?(story_id, project_id) when is_binary(project_id) do
    Repo.exists?(
      from s in "stories",
        where: s.id == ^story_id and s.project_id != type(^project_id, :binary_id)
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
