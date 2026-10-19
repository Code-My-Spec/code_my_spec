defmodule CodeMySpec.Issues do
  @moduledoc """
  The Issues context.

  Issues live in whatever database this application is talking to, and
  every function here writes it directly. The local application keeps its
  own issues and does not replicate or sync anybody else's.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Accounts,
      CodeMySpec.Projects,
      CodeMySpec.Qa.Invalidations,
      CodeMySpec.Repo,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils
    ],
    exports: :all

  require Logger

  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Issues.IssuesRepository
  alias CodeMySpec.Issues.StorySubmissions
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Users.Scope

  # -- Reads ------------------------------------------------------------------

  def list_issues(%Scope{} = scope) do
    IssuesRepository.list_issues(scope)
  end

  def list_by_status(%Scope{} = scope, status) do
    IssuesRepository.list_by_status(scope, status)
  end

  @doc """
  Whether this project already has an unfinished issue with exactly this title.

  See `IssuesRepository.open_issue_titled?/2`. Exposed because the fault paths
  in `MainAgent` file by a title built from the fault, and a fault that persists
  is reported by every call that notices it.

  Unfinished means anything but `:resolved` — a dismissed fault recurring is
  still not worth acting on, a resolved one recurring is a regression.
  """
  @spec open_issue_titled?(Scope.t(), String.t()) :: boolean()
  def open_issue_titled?(%Scope{} = scope, title),
    do: IssuesRepository.open_issue_titled?(scope, title)

  def list_by_status_and_min_severity(%Scope{} = scope, status, min_severity) do
    IssuesRepository.list_by_status_and_min_severity(scope, status, min_severity)
  end

  def list_by_story(%Scope{} = scope, story_id) do
    IssuesRepository.list_by_story(scope, story_id)
  end

  @doc """
  Attribute unattributed `:app` issues to a story. Returns the count updated.

  Called when a QA attempt is submitted: the agent has just named these
  issues as the findings of a pass over one story. The inherited submission
  graph reads `story_id` to place accepted blocking fixes before shared story
  QA; promotion completes the reviewed submissions. Done here because agents
  do not reliably pass `story_id` to `create_issue`.
  """
  def attribute_to_story(%Scope{} = scope, issue_ids, story_id)
      when is_list(issue_ids) and not is_nil(story_id) do
    IssuesRepository.attribute_to_story(scope, issue_ids, story_id)
  end

  def attribute_to_story(_scope, _issue_ids, _story_id), do: 0

  @doc "Loads each issue's story, so it can be named by number."
  def with_story(%Issue{} = issue), do: CodeMySpec.Repo.preload(issue, :story)
  def with_story(issue), do: issue

  def get_issue(%Scope{} = scope, id) do
    IssuesRepository.get_issue(scope, id)
  end

  @doc """
  Every framework-scoped issue across every project, for the vendor.

  See `CodeMySpec.Issues.IssuesRepository.list_framework_issues/1` — framework
  issues live in the project that filed them, and this is the one place that
  crosses a boundary to collect them.
  """
  defdelegate list_framework_issues(scope), to: IssuesRepository

  @doc """
  An issue by full id or unique prefix — `{:ok, issue} | :not_found | {:ambiguous, ids}`.

  See `CodeMySpec.Issues.IssuesRepository.fetch_issue/2`. Use this over
  `get_issue/2` wherever the answer is shown to somebody, so an ambiguous prefix
  can say so instead of being reported as a missing issue.
  """
  defdelegate fetch_issue(scope, id), to: IssuesRepository

  def get_issue!(%Scope{} = scope, id) do
    IssuesRepository.get_issue!(scope, id)
  end

  @doc "See `CodeMySpec.Issues.IssuesRepository.latest_story_submissions/2`."
  defdelegate latest_story_submissions(project_id, story_ids), to: IssuesRepository
  defdelegate incoming_by_story(scope), to: IssuesRepository
  defdelegate list_triageable(scope, min_severity), to: IssuesRepository

  @doc """
  Resolved issues in one project, by id, for callers that hold an id rather
  than a scope.

  `list_issues/1` and its neighbours read the loaded `scope.active_project`,
  which a caller holding only an id does not have.
  """
  @spec resolved_in_project(Ecto.UUID.t()) :: [%{id: String.t(), title: String.t()}]
  def resolved_in_project(project_id) when is_binary(project_id) do
    IssuesRepository.resolved_in_project(project_id)
  end

  def list_filtered(%Scope{} = scope, filters) do
    IssuesRepository.list_filtered(scope, filters)
  end

  @doc "Accepted issues inherited from a story, excluding explicitly assigned issue bags."
  defdelegate list_story_submissions(scope, story_id), to: StorySubmissions, as: :list

  @doc "Current submission identities; nil values identify fixes still awaiting coding."
  def story_submission_snapshot(scope, story_id, threshold \\ :medium),
    do: StorySubmissions.snapshot(scope, story_id, threshold)

  defdelegate story_submission_snapshots(scope, story_ids, threshold),
    to: StorySubmissions,
    as: :snapshots

  defdelegate story_issue_submitted?(issue), to: StorySubmissions, as: :submitted?

  @doc "Submit an inherited story fix and invalidate qualifying QA in the same transaction."
  def submit_story_issue(scope, issue, attrs) do
    case StorySubmissions.submit(scope, issue, attrs) do
      {:ok, {updated, changed?}} ->
        if changed?, do: broadcast(scope, {:updated, updated})
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def rework_story_submissions(scope, story_id, snapshot, issue_ids, reason) do
    with {:ok, issues} <- StorySubmissions.rework(scope, story_id, snapshot, issue_ids, reason) do
      Enum.each(issues, &broadcast(scope, {:updated, &1}))
      {:ok, issues}
    end
  end

  def complete_story_submissions(scope, story_id, snapshot, landed_commit) do
    with {:ok, issues} <- StorySubmissions.complete(scope, story_id, snapshot, landed_commit) do
      Enum.each(issues, &broadcast(scope, {:resolved, &1}))
      {:ok, issues}
    end
  end

  # -- Create -----------------------------------------------------------------

  def create_issue(%Scope{} = scope, attrs) do
    with {:ok, issue} <- IssuesRepository.create_issue(scope, attrs) do
      broadcast(scope, {:created, issue})

      {:ok, issue}
    end
  end

  @doc """
  Widget-side issue report: an end-user of a client app files an issue through
  the support widget, authenticated at the socket by the project's deploy key
  (server-to-server — no CMS user `Scope`). Mirrors `create_issue/2` but takes
  the account/project ids directly, stamps `source: "widget"` and `scope: :app`
  unless overridden, and broadcasts `{:created, issue}` so local mirrors and the
  operator dashboard pick it up like any other issue.

  `attrs` are string-keyed (title/description/severity from the widget form).
  """
  def report_from_widget(account_id, project_id, attrs)
      when is_binary(account_id) and is_binary(project_id) and is_map(attrs) do
    scope = %Scope{active_account_id: account_id, active_project_id: project_id}

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put_new("source", "widget")
      |> Map.put_new("scope", "app")

    create_issue(scope, attrs)
  end

  @doc """
  Deploy-key-authenticated framework issue report for clients with no OAuth
  session (widget-style embeds and other external reporters) — the deploy key
  resolves the project via its blind-index hash, same flow as
  `report_from_widget/3`. Scope is forced to `framework` so the key grants
  nothing broader. Installed CLIs don't take this path; they file framework
  issues over their OAuth session via `ProjectScopeOverride`.
  """
  def report_framework_issue(account_id, project_id, attrs)
      when is_binary(account_id) and is_binary(project_id) and is_map(attrs) do
    scope = %Scope{active_account_id: account_id, active_project_id: project_id}

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("scope", "framework")
      |> Map.put_new("source", "cli")

    create_issue(scope, attrs)
  end

  @doc """
  Report an issue from an end user of a generated app.

  The deploy key identifies the project; the reporter is not authenticated
  and needs no CodeMySpec account. Scoped `"app"`, defaulting to `medium`
  severity.
  """
  @spec report_widget_issue(String.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def report_widget_issue(account_id, project_id, attrs)
      when is_binary(account_id) and is_binary(project_id) and is_map(attrs) do
    scope = %Scope{active_account_id: account_id, active_project_id: project_id}

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("scope", "app")
      |> Map.put_new("source", "widget")
      |> Map.put_new("severity", "medium")

    create_issue(scope, attrs)
  end

  @doc """
  Creates issues from a validated QA result document.

  Parses the issues section, upserts each issue (skipping duplicates by title + story_id),
  and projects all created issues to the filesystem. `source_path` is the result
  file the issues were read from.
  """
  def create_from_qa_result(%Scope{} = scope, story_id, document, source_path) do
    issues = Map.get(document.sections, "issues", [])

    created =
      issues
      |> Enum.filter(&fileable?/1)
      |> Enum.map(fn qa_issue ->
        attrs = %{
          title: qa_issue.title,
          severity: parse_severity(qa_issue.severity),
          scope: parse_scope(qa_issue.scope),
          description: qa_issue.description,
          story_id: story_id,
          source_path: source_path
        }

        case upsert_or_create(scope, attrs) do
          {:ok, issue} -> issue
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, created}
  end

  # Whether a parsed QA-result issue has a recognized severity at all. The only
  # check upstream of `parse_severity/1`, which never fails (an unknown string
  # becomes `:medium`). Matches on `.severity`, not the `QaIssue` struct, so
  # Issues need not depend on Documents.
  @fileable_severities ~w(critical high medium low info)

  @spec fileable?(%{severity: String.t()}) :: boolean()
  def fileable?(%{severity: s}) when s in @fileable_severities, do: true
  def fileable?(_), do: false

  @doc """
  Creates an issue from a braindump markdown file.

  Braindump issues default to :accepted status and :medium severity.
  """
  def create_from_braindump(%Scope{} = scope, content, attrs \\ %{}) do
    {title, description} = parse_braindump(content)

    merged =
      Map.merge(
        %{
          title: title,
          description: description,
          severity: :medium,
          scope: :app,
          status: :accepted
        },
        attrs
      )

    IssuesRepository.create_issue(scope, merged)
  end

  # -- Status transitions -----------------------------------------------------

  def accept_issue(%Scope{} = scope, %Issue{} = issue, opts \\ []) do
    with {:ok, issue} <- IssuesRepository.update_status(issue, :accepted, nil, opts) do
      broadcast(scope, {:accepted, issue})
      {:ok, issue}
    end
  end

  def dismiss_issue(%Scope{} = scope, %Issue{} = issue, reason) do
    with {:ok, issue} <- IssuesRepository.update_status(issue, :dismissed, reason) do
      broadcast(scope, {:dismissed, issue})
      {:ok, issue}
    end
  end

  def resolve_issue(
        %Scope{},
        %Issue{story_id: story_id, assigned_working_copy_id: nil},
        _resolution
      )
      when not is_nil(story_id),
      do: {:error, :story_issue_requires_shared_qa_and_promotion}

  def resolve_issue(%Scope{} = scope, %Issue{} = issue, resolution) do
    with {:ok, issue} <- IssuesRepository.update_status(issue, :resolved, resolution) do
      broadcast(scope, {:resolved, issue})
      {:ok, issue}
    end
  end

  @doc """
  Set or clear which copy's team this issue is assigned to.

  A fresh assignment (the issue held none before) starts the coder's turn.
  Moving an already-assigned issue to another copy carries whose turn it
  currently is along with it, unchanged.
  """
  @spec set_assigned_working_copy(Scope.t(), Issue.t(), Ecto.UUID.t() | nil) ::
          {:ok, Issue.t()} | {:error, term()}
  def set_assigned_working_copy(%Scope{} = scope, %Issue{} = issue, working_copy_id) do
    awaiting_role = next_awaiting_role(issue, working_copy_id)

    with {:ok, updated} <-
           IssuesRepository.update_assignment(issue, working_copy_id, awaiting_role) do
      broadcast(scope, {:updated, updated})
      {:ok, updated}
    end
  end

  defp next_awaiting_role(_issue, nil), do: nil
  defp next_awaiting_role(%Issue{assigned_working_copy_id: nil}, _new_copy_id), do: :coding
  defp next_awaiting_role(%Issue{awaiting_role: role}, _new_copy_id), do: role

  @doc """
  Flip whose turn it is on an issue already assigned to a copy: the coder's
  until it submits a fix, QA's until it submits a non-passing attempt, the
  coder's again (`:promote`) to land a fix QA passed.
  """
  @spec set_awaiting_role(Scope.t(), Issue.t(), :coding | :qa | :promote) ::
          {:ok, Issue.t()} | {:error, term()}
  def set_awaiting_role(%Scope{} = scope, %Issue{} = issue, role)
      when role in [:coding, :qa, :promote] do
    with {:ok, updated} <- IssuesRepository.update_awaiting_role(issue, role) do
      broadcast(scope, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc "The accepted issue assigned to `working_copy_id`'s team, or nil."
  @spec assigned_to_copy(Scope.t(), Ecto.UUID.t()) :: Issue.t() | nil
  defdelegate assigned_to_copy(scope, working_copy_id), to: IssuesRepository

  @doc """
  Stamps `issue` ready for QA at `commit` — the commit `Promotion.certify/3`
  passed at. With `clear_qa_ready/2`, the only writer of `qa_ready_commit`;
  `IssueFix` reads it.
  """
  @spec set_qa_ready(Scope.t(), Issue.t(), String.t(), DateTime.t()) ::
          {:ok, Issue.t()} | {:error, term()}
  def set_qa_ready(%Scope{} = scope, %Issue{} = issue, commit, at \\ DateTime.utc_now())
      when is_binary(commit) do
    with {:ok, updated} <- IssuesRepository.update_qa_ready_commit(issue, commit, at) do
      broadcast(scope, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  Removes `issue`'s QA-ready stamp: a failed QA attempt means the certified
  commit is not the fix, so the rework has to be certified afresh.
  """
  @spec clear_qa_ready(Scope.t(), Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def clear_qa_ready(%Scope{} = scope, %Issue{} = issue) do
    with {:ok, updated} <- IssuesRepository.clear_qa_ready_commit(issue) do
      broadcast(scope, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc "Record the commit an issue's fix landed on main at."
  @spec record_fix_landed(Scope.t(), Issue.t(), String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def record_fix_landed(%Scope{} = scope, %Issue{} = issue, commit) do
    with {:ok, updated} <- IssuesRepository.update_landed_commit(issue, commit) do
      broadcast(scope, {:updated, updated})
      {:ok, updated}
    end
  end

  @doc """
  Update non-status fields on an existing issue (severity, story_id,
  category, source_path). Status transitions go through
  `accept_issue` / `dismiss_issue` / `resolve_issue` — this is the
  catch-all for everything else.
  """
  def update_issue(%Scope{} = scope, %Issue{} = issue, attrs) do
    with {:ok, updated} <- IssuesRepository.update_attributes(issue, attrs) do
      broadcast(scope, {:updated, updated})
      {:ok, updated}
    end
  end

  # -- Query helpers ----------------------------------------------------------

  def has_unresolved_issues?(%Scope{} = scope, min_severity \\ :medium) do
    IssuesRepository.count_by_status_and_min_severity(scope, :accepted, min_severity) > 0
  end

  def has_untriaged_issues?(%Scope{} = scope, min_severity \\ :medium) do
    IssuesRepository.count_by_status_and_min_severity(scope, :incoming, min_severity) > 0
  end

  # -- Private ----------------------------------------------------------------

  defp upsert_or_create(scope, attrs) do
    case IssuesRepository.upsert_issue(scope, attrs) do
      {:ok, issue, _status} -> {:ok, issue}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_severity(s) when is_atom(s), do: s

  defp parse_severity(s) when is_binary(s) do
    case String.downcase(s) do
      "critical" -> :critical
      "high" -> :high
      "medium" -> :medium
      "low" -> :low
      "info" -> :info
      _ -> :medium
    end
  end

  defp parse_scope(s) when is_atom(s), do: s

  defp parse_scope(s) when is_binary(s) do
    case String.downcase(s) do
      "app" -> :app
      "qa" -> :qa
      "docs" -> :docs
      "framework" -> :framework
      _ -> :app
    end
  end

  defp parse_scope(nil), do: :app

  defp parse_braindump(content) do
    case Regex.run(~r/^#\s+(.+)$/m, content) do
      [_, title] ->
        description =
          content
          |> String.replace(~r/^#\s+.+\n*/, "")
          |> String.trim()

        {title, description}

      nil ->
        lines = String.split(content, "\n", parts: 2)
        title = List.first(lines) |> String.trim()
        description = Enum.at(lines, 1, "") |> String.trim()
        {title, description}
    end
  end

  def subscribe(%Scope{active_account_id: account_id}) when is_binary(account_id) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{account_id}:issues")
  end

  defp broadcast(%Scope{active_account_id: account_id} = scope, message)
       when is_binary(account_id) do
    announce_finished(scope, message)
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{account_id}:issues", message)

    # The event, not an invalidation: `Requirements.Handlers` settles the issue
    # requirements from it directly. `graph_entities/1` rides along for a kind
    # with no handler.
    GraphInputs.event(
      scope,
      "Issues",
      event_kind(message),
      event_payload(message),
      graph_entities(message),
      :project_wide
    )
  end

  defp broadcast(_scope, _message), do: :ok

  # Retire outstanding work offers before publishing a change that can wake agents.
  defp announce_finished(scope, {status, issue}) when status in [:resolved, :dismissed] do
    :telemetry.execute([:code_my_spec, :issues, :finished], %{}, %{scope: scope, issue: issue})
  end

  defp announce_finished(_scope, _message), do: :ok

  defp event_kind({:created, _}), do: "issue_created"
  defp event_kind({:accepted, _}), do: "issue_accepted"
  defp event_kind({:dismissed, _}), do: "issue_dismissed"
  defp event_kind({:resolved, _}), do: "issue_resolved"
  defp event_kind({:updated, _}), do: "issue_updated"
  defp event_kind(_), do: "issue_changed"

  defp event_payload({_verb, %{} = issue}),
    do: %{
      "id" => issue.id,
      "severity" => issue.severity && to_string(issue.severity),
      "status" => issue.status && to_string(issue.status),
      "story_id" => Map.get(issue, :story_id)
    }

  defp event_payload(_message), do: %{}

  # The story it was attributed to, if any, and always the project.
  #
  # Project events maintain project triage and explicit issue branches. A
  # story event rebuilds its inherited submission branches and shared QA
  # prerequisites. Unattributed issues do not change another story's graph.
  defp graph_entities({_verb, %{story_id: story_id}}) when not is_nil(story_id),
    do: [{"story", story_id}, :project]

  defp graph_entities(_message), do: [:project]
end
