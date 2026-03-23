defmodule CodeMySpecLocalWeb.SessionsMarkdown do
  @moduledoc """
  Markdown rendering for sessions.

  Shared by both the LLM API (plain text) and the human UI (rendered via MDEx).
  """

  alias CodeMySpec.Sessions.Session

  @doc "Render a list of sessions as markdown."
  def index(sessions, project) do
    slug = project_slug(project)
    total = length(sessions)
    active = Enum.count(sessions, &(&1.status == :active))

    header = "# Sessions (#{active} active / #{total} total)\n\n"

    if sessions == [] do
      header <> "No sessions found."
    else
      lines =
        Enum.map_join(sessions, "\n", fn session ->
          status_icon = status_icon(session.status)
          type_name = format_type(session.type)
          task_summary = task_summary(session)
          external = if session.external_conversation_id, do: " `#{truncate(session.external_conversation_id, 12)}`", else: ""
          time = if session.inserted_at, do: " — #{Calendar.strftime(session.inserted_at, "%Y-%m-%d %H:%M")}", else: ""

          "- #{status_icon} [#{type_name}](/projects/#{slug}/sessions/#{session.id})#{external}#{task_summary}#{time}"
        end)

      header <> lines <> "\n"
    end
  end

  @doc "Render a single session with its tasks."
  def show(%Session{} = session, project) do
    slug = project_slug(project)
    back = "[← Back to sessions](/projects/#{slug}/sessions)\n\n"

    type_name = format_type(session.type)
    status = "#{status_icon(session.status)} #{session.status}"

    header = "# Session: #{type_name}\n\n**Status:** #{status}\n"

    meta =
      [
        if(session.external_conversation_id, do: "**External ID:** `#{session.external_conversation_id}`"),
        if(session.component_module_name, do: "**Component:** #{session.component_module_name}"),
        if(session.inserted_at, do: "**Started:** #{Calendar.strftime(session.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}"),
        if(session.updated_at, do: "**Updated:** #{Calendar.strftime(session.updated_at, "%Y-%m-%d %H:%M:%S UTC")}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    tasks_section = render_tasks(session.tasks || [], session.id, slug)

    state_section =
      if session.state && session.state != %{} do
        "\n\n## State\n\n```json\n#{Jason.encode!(session.state, pretty: true)}\n```"
      else
        ""
      end

    back <> header <> "\n" <> meta <> tasks_section <> state_section <> "\n"
  end

  # -- Private ----------------------------------------------------------------

  defp render_tasks([], _session_id, _slug), do: "\n\n## Tasks\n\nNo tasks recorded."

  defp render_tasks(tasks, session_id, slug) do
    total = length(tasks)
    completed = Enum.count(tasks, &(&1.status in [:completed, :failed, :cancelled]))

    header = "\n\n## Tasks (#{completed}/#{total})\n\n"

    lines =
      Enum.map_join(tasks, "\n", fn task ->
        icon = status_icon(task.status)
        type_name = format_type(task.session_type)
        component = if task.component_module_name, do: " — #{task.component_module_name}", else: ""
        requirement = if task.requirement_name, do: " (#{task.requirement_name})", else: ""

        time =
          cond do
            task.completed_at -> " — completed #{Calendar.strftime(task.completed_at, "%H:%M:%S")}"
            task.started_at -> " — started #{Calendar.strftime(task.started_at, "%H:%M:%S")}"
            true -> ""
          end

        "- #{icon} [**#{type_name}**](/projects/#{slug}/sessions/#{session_id}/tasks/#{task.id})#{component}#{requirement}#{time}"
      end)

    header <> lines
  end

  defp status_icon(:active), do: "🔵"
  defp status_icon(:completed), do: "✅"
  defp status_icon(:complete), do: "✅"
  defp status_icon(:failed), do: "❌"
  defp status_icon(:cancelled), do: "⚪"
  defp status_icon(:prepared), do: "⏳"
  defp status_icon(_), do: "○"

  defp format_type(nil), do: "Unknown"

  defp format_type(type) when is_atom(type) do
    type |> Atom.to_string() |> String.split(".") |> List.last()
  end

  defp format_type(type) when is_binary(type), do: type

  defp task_summary(%{tasks: tasks}) when is_list(tasks) and tasks != [] do
    active = Enum.count(tasks, &(&1.status == :active))
    completed = Enum.count(tasks, &(&1.status in [:completed, :failed, :cancelled]))
    total = length(tasks)
    " (#{completed}/#{total} tasks" <> if(active > 0, do: ", #{active} active)", else: ")")
  end

  defp task_summary(_), do: ""

  defp truncate(str, len) when byte_size(str) > len, do: String.slice(str, 0, len) <> "…"
  defp truncate(str, _len), do: str

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
