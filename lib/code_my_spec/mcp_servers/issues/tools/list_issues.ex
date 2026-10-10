defmodule CodeMySpec.McpServers.Issues.Tools.ListIssues do
  @moduledoc """
  Lists issues in a project with optional filters.

  Filter by status (incoming, accepted, dismissed, resolved),
  severity (critical, high, medium, low, info), scope (app, qa, docs,
  framework), or story_number.

  `framework` used to be excluded here, on the grounds that framework issues
  routed to the hosted server rather than being stored locally. That stopped
  being true when the tools moved onto the server — see `CreateIssue`, which
  writes every scope the same way — so they were creatable, visible in an
  unfiltered listing, and impossible to filter for.
  """

  use Anubis.Server.Component, type: :tool

  @behaviour CodeMySpec.McpServers.ScriptResult

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.StoryRefs
  alias CodeMySpec.McpServers.Validators

  schema do
    field :status, :string,
      doc:
        "open (default: incoming and accepted), all, or one of incoming, accepted, dismissed, resolved"

    field :severity, :string,
      doc: "medium or higher by default; all, or one of critical, high, medium, low, info"

    field :scope, :string, doc: "Filter by scope: app, qa, docs, framework"
    field :story_number, :integer, doc: "Filter by the related story's number"

    field :working_copy_id, :string,
      doc: "Filter by assigned working copy (use severity all to include the entire bag)"

    field :query, :string, doc: "Text that the title or description contains (case-insensitive)"
    field :limit, :integer, doc: "Most issues to return, newest first (default 50)"
  end

  # 6da8e0e5: the default was every issue, by severity, and the reply is cut at
  # 24KB. On metric_flow that was 547 issues and about 150 rows shown — critical
  # and high — so a medium issue John had just filed from the widget never
  # appeared, and main told him nothing had landed. Open and newest first is
  # what an agent asking "what is there" means, and the footer says what was
  # left out and how to reach it. Low and info are left out too unless asked
  # for — John, 10-01: what an agent needs from a listing is what to act on.
  @open [:incoming, :accepted]
  @medium_up [:critical, :high, :medium]
  @default_limit 50

  # Atoms, not strings, and that is load-bearing rather than stylistic.
  #
  # `validate_filter/3` used to whitelist a string and then call
  # `String.to_existing_atom/1` on it — which raises `:badarg` unless something
  # else has already caused that atom to exist. It runs *before* any query, so
  # on a freshly restarted server `CodeMySpec.Issues.Issue` may not be loaded
  # and its `@scopes` attribute may not have created anything.
  #
  # `:app`, `:qa` and `:docs` survived that by luck: they are common enough to
  # exist for a dozen unrelated reasons. `:framework` is not, and adding it
  # turned every `scope: "framework"` call into `-32603 Internal error` on a
  # cold server — a crash inside a function whose whole job is validation.
  #
  # Written as atoms here, the list itself makes them exist at compile time and
  # the conversion disappears.
  @valid_statuses [:incoming, :accepted, :dismissed, :resolved]
  @valid_severities [:critical, :high, :medium, :low, :info]

  # `framework` belongs here. It was excluded because framework issues were
  # POSTed to the hosted server rather than stored locally — but `CreateIssue`
  # records that this stopped being true when the tools moved onto the server:
  # "Every scope writes the same way. Framework issues used to be special …
  # that path had the server authenticating to itself as a CLI".
  #
  # So they are created locally, appear in an unfiltered listing, and could not
  # be filtered for — the one combination that reads as data loss. An agent
  # asked to work the framework backlog got `Invalid scope: "framework".
  # Allowed: app, qa, docs.` while the issues sat two lines above in the
  # unfiltered list.
  @valid_scopes [:app, :qa, :docs, :framework]

  @impl true
  def execute(params, frame) do
    case matching(params, frame) do
      {:ok, matching, shown} ->
        issues = Enum.take(matching, limit(params[:limit]))
        {:reply, IssuesMapper.issues_list_response(issues, shown, length(matching)), frame}

      {:error, reason} ->
        {:reply, IssuesMapper.error(error_message(reason)), frame}
    end
  end

  @impl CodeMySpec.McpServers.ScriptResult
  def script_result(params, frame) do
    case matching(params, frame) do
      {:ok, matching, _shown} ->
        {:ok, matching |> Enum.take(limit(params[:limit])) |> Enum.map(&row/1)}

      {:error, reason} ->
        {:error, error_message(reason)}
    end
  end

  # Lifted out of `execute/2` so the script path runs the same query rather
  # than a second copy of it.
  defp matching(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, filters} <- build_filters(params),
         {:ok, story_id} <- StoryRefs.story_id(scope, params[:story_number]) do
      {statuses, filters} = Map.pop(filters, :statuses)
      {severities, filters} = Map.pop(filters, :severities)

      matching =
        scope
        |> list(maybe_put(filters, :story_id, story_id))
        |> Enum.filter(
          &(in?(&1.status, statuses) and in?(&1.severity, severities) and
              contains?(&1, params[:query]) and
              (is_nil(params[:working_copy_id]) or
                 &1.assigned_working_copy_id == params[:working_copy_id]))
        )
        |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

      shown =
        filters
        |> Map.put(:status, status_label(statuses))
        |> Map.put(:severity, severity_label(severities))
        |> maybe_put(:story_number, params[:story_number])
        |> maybe_put(:query, params[:query])
        |> maybe_put(:working_copy_id, params[:working_copy_id])

      {:ok, matching, shown}
    end
  end

  defp error_message({:invalid_value, field, value, allowed}),
    do: "Invalid #{field}: #{inspect(value)}. Allowed: #{Enum.join(allowed, ", ")}."

  defp error_message(reason), do: reason

  # String keys and plain values: these cross into a Lua VM, where an atom
  # key and a struct are not things that exist.
  defp row(issue) do
    %{
      "id" => issue.id,
      "title" => issue.title,
      "severity" => to_string(issue.severity),
      "scope" => to_string(issue.scope),
      "status" => to_string(issue.status),
      "description" => issue.description,
      "story_id" => issue.story_id,
      "assigned_working_copy_id" => issue.assigned_working_copy_id,
      "awaiting_role" => to_string(issue.awaiting_role),
      "inserted_at" => issue.inserted_at && DateTime.to_iso8601(issue.inserted_at)
    }
  end

  # `scope: framework` asked from CodeMySpec's own project is the vendor's
  # backlog, and it spans every project.
  #
  # Framework issues are friction with CodeMySpec, filed by agents working in
  # other people's projects, and they live where they were filed — one
  # invariant, no exception on any write. So the one place that crosses a
  # boundary is this read, and only for the vendor: `list_framework_issues/1`
  # refuses anyone whose active project is not the configured CodeMySpec one,
  # and this falls back to the ordinary project-scoped listing when it does.
  #
  # That fallback is what makes the filter mean the same thing everywhere. In
  # any other project, `scope: framework` still lists that project's own
  # framework issues — the ones it filed — which is exactly what its author
  # wants to see.
  defp list(scope, %{scope: :framework} = filters) do
    case Issues.list_framework_issues(scope) do
      {:ok, issues} -> apply_local_filters(issues, filters)
      {:error, :not_the_vendor} -> Issues.list_filtered(scope, filters)
    end
  end

  defp list(scope, filters), do: Issues.list_filtered(scope, filters)

  # The vendor query answers one question — every framework issue — so the
  # other filters are applied here rather than pushed into it. Keeps the
  # cross-project surface to a single, auditable query.
  defp apply_local_filters(issues, filters) do
    issues
    |> filter_by(:status, filters)
    |> filter_by(:severity, filters)
    |> filter_by(:story_id, filters)
  end

  defp filter_by(issues, key, filters) do
    case Map.fetch(filters, key) do
      {:ok, value} -> Enum.filter(issues, &(Map.get(&1, key) == value))
      :error -> issues
    end
  end

  defp build_filters(params) do
    with {:ok, statuses} <- statuses(params[:status]),
         {:ok, severities} <- severities(params[:severity]),
         {:ok, scope} <- validate_filter(params[:scope], :scope, @valid_scopes) do
      filters =
        %{statuses: statuses, severities: severities}
        |> maybe_put(:scope, scope)

      {:ok, filters}
    end
  end

  defp statuses(nil), do: {:ok, @open}
  defp statuses("open"), do: {:ok, @open}
  defp statuses("all"), do: {:ok, nil}

  defp statuses(value) do
    case validate_filter(value, :status, @valid_statuses) do
      {:ok, status} ->
        {:ok, [status]}

      {:error, {:invalid_value, field, value, allowed}} ->
        {:error, {:invalid_value, field, value, [:open, :all | allowed]}}
    end
  end

  defp severities(nil), do: {:ok, @medium_up}
  defp severities("all"), do: {:ok, nil}

  defp severities(value) do
    case validate_filter(value, :severity, @valid_severities) do
      {:ok, severity} ->
        {:ok, [severity]}

      {:error, {:invalid_value, field, value, allowed}} ->
        {:error, {:invalid_value, field, value, [:all | allowed]}}
    end
  end

  defp in?(_value, nil), do: true
  defp in?(value, allowed), do: value in allowed

  defp severity_label(nil), do: "all"
  defp severity_label(@medium_up), do: "medium or higher"
  defp severity_label([severity]), do: severity

  defp status_label(nil), do: "all"
  defp status_label(@open), do: "open"
  defp status_label([status]), do: status

  defp contains?(_issue, query) when query in [nil, ""], do: true

  defp contains?(issue, query) do
    needle = String.downcase(query)

    Enum.any?([issue.title, issue.description], fn text ->
      is_binary(text) and String.contains?(String.downcase(text), needle)
    end)
  end

  defp limit(n) when is_integer(n) and n > 0, do: n
  defp limit(_), do: @default_limit

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp validate_filter(nil, _field, _allowed), do: {:ok, nil}

  # Matched by string form against a list of atoms, so nothing is converted and
  # the load-order trap above cannot come back.
  defp validate_filter(value, field, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_value, field, value, allowed}}
      atom -> {:ok, atom}
    end
  end

  defp validate_filter(value, field, allowed) when is_atom(value) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_value, field, value, allowed}}
  end
end
