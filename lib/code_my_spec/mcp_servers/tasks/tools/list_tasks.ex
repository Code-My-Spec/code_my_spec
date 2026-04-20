defmodule CodeMySpec.McpServers.Tasks.Tools.ListTasks do
  @moduledoc """
  List all tasks on the current session.

  Returns task status, agent assignment, component, and requirement
  so the main agent can track subagent progress.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Sessions

  schema do
    field :session_id, :string,
      doc: "Injected by hook — do not set manually"

    field :status, :string,
      doc: "Filter by status: active, completed, failed, cancelled (optional)"
  end

  @impl true
  def execute(params, frame) do
    session_id = Map.get(params, :session_id)
    status_filter = Map.get(params, :status)

    with {:ok, status} <- parse_status(status_filter),
         {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, session} <- resolve_session(scope, session_id) do
      tasks = session.tasks || []

      tasks =
        if status do
          Enum.filter(tasks, &(&1.status == status))
        else
          tasks
        end

      text =
        if tasks == [] do
          "No tasks on this session."
        else
          header = "# Session Tasks (#{length(tasks)})\n\n"

          rows =
            Enum.map_join(tasks, "\n", fn t ->
              status_icon =
                case t.status do
                  :completed -> "✓"
                  :active -> "●"
                  :failed -> "✗"
                  :cancelled -> "—"
                  :prepared -> "○"
                  _ -> "?"
                end

              agent = if t.agent_id, do: "agent=#{t.agent_id}", else: "unassigned"
              component = t.component_module_name || "—"

              "- #{status_icon} **#{t.requirement_name}** #{component} [#{t.status}] #{agent} `#{t.id}`"
            end)

          header <> rows
        end

      response = Response.tool() |> Response.text(text)
      {:reply, response, frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{reason}"), frame}
    end
  end

  defp resolve_session(scope, session_id) when is_binary(session_id) and session_id != "" do
    case Sessions.get_by_external_id(scope, session_id) do
      nil -> {:error, "Session not found: #{session_id}"}
      session -> {:ok, session}
    end
  end

  defp resolve_session(_scope, _), do: {:error, "No session_id available"}

  @valid_statuses ~w(prepared active completed failed cancelled)

  defp parse_status(nil), do: {:ok, nil}
  defp parse_status(s) when is_binary(s) do
    if s in @valid_statuses do
      {:ok, String.to_existing_atom(s)}
    else
      {:error,
       "Invalid status: #{inspect(s)}. Allowed: #{Enum.join(@valid_statuses, ", ")}."}
    end
  end
end
