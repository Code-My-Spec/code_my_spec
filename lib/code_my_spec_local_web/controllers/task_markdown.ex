defmodule CodeMySpecLocalWeb.TaskMarkdown do
  @moduledoc """
  Markdown rendering for a single task.
  """

  alias CodeMySpec.Sessions.Task

  def show(%Task{} = task, session, project) do
    slug = project_slug(project)
    back = "[← Back to session](/projects/#{slug}/sessions/#{session.id})\n\n"

    type_name = format_type(task.session_type)
    status = "#{status_icon(task.status)} #{task.status}"

    header = "# Task: #{type_name}\n\n**Status:** #{status}\n"

    meta =
      [
        if(task.requirement_name, do: "**Requirement:** #{task.requirement_name}"),
        if(task.component_module_name, do: "**Component:** #{task.component_module_name}"),
        if(task.component_id, do: "**Component ID:** `#{task.component_id}`"),
        if(task.story_id, do: "**Story ID:** #{task.story_id}"),
        if(task.project_id, do: "**Project ID:** `#{task.project_id}`"),
        if(task.agent_id, do: "**Agent ID:** `#{task.agent_id}`"),
        if(task.started_at, do: "**Started:** #{Calendar.strftime(task.started_at, "%Y-%m-%d %H:%M:%S UTC")}"),
        if(task.completed_at, do: "**Completed:** #{Calendar.strftime(task.completed_at, "%Y-%m-%d %H:%M:%S UTC")}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    files_section =
      case task.expected_files do
        files when is_list(files) and files != [] ->
          lines = Enum.map_join(files, "\n", &("- `#{&1}`"))
          "\n\n## Expected Files\n\n#{lines}"

        _ ->
          ""
      end

    back <> header <> "\n" <> meta <> files_section <> "\n"
  end

  defp status_icon(:active), do: "🔵"
  defp status_icon(:completed), do: "✅"
  defp status_icon(:failed), do: "❌"
  defp status_icon(:cancelled), do: "⚪"
  defp status_icon(:prepared), do: "⏳"
  defp status_icon(_), do: "○"

  defp format_type(nil), do: "Unknown"
  defp format_type(type) when is_atom(type), do: type |> Atom.to_string() |> String.split(".") |> List.last()
  defp format_type(type) when is_binary(type), do: type

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
