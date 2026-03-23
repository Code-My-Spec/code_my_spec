defmodule CodeMySpecLocalWeb.NextTaskMarkdown do
  @moduledoc """
  Markdown rendering for the next actionable task.

  Shared by both the LLM API (plain text) and the human UI (rendered via MDEx).
  """

  alias CodeMySpec.Repo

  @doc """
  Build markdown for a next-task result.

  When a task_id is provided, includes a start-task link that gates the prompt.
  """
  def render({:ok, requirement}, _scope, project, task_id \\ nil) do
    requirement = Repo.preload(requirement, [:component, :story])
    slug = project_slug(project)

    sections = [
      back_link(slug),
      header(requirement),
      entity_context(requirement, slug, project),
      start_link(requirement, slug, task_id)
    ]

    Enum.reject(sections, &is_nil/1) |> Enum.join("\n\n")
  end

  def render(:complete, _scope, project, _task_id) do
    slug = project_slug(project)
    "[← Back to requirements](/projects/#{slug}/requirements)\n\n# All requirements satisfied\n\nNo actionable tasks remain."
  end

  def render({:error, reason}, _scope, project, _task_id) do
    slug = project_slug(project)
    "[← Back to requirements](/projects/#{slug}/requirements)\n\n# No actionable task\n\n#{reason}"
  end

  # -- Private ----------------------------------------------------------------

  defp back_link(slug) do
    "[← Back to requirements](/projects/#{slug}/requirements)"
  end

  defp header(req) do
    status = if req.satisfied, do: "✓ Satisfied", else: "Not satisfied"
    score = if req.score, do: " (#{Float.round(req.score, 2)})", else: ""
    scope_tag = if req.scope != :local, do: " | scope: `#{req.scope}`", else: ""

    "# Next Task: #{req.name}\n\n#{req.description}\n\n**#{status}#{score}**#{scope_tag}"
  end

  defp entity_context(req, slug, project) do
    case {req.component, req.story} do
      {%{id: id, module_name: name, type: type}, _} ->
        "**Component:** [#{name}](/projects/#{slug}/components/#{id}) (#{type})"

      {_, %{id: id, title: title}} ->
        "**Story:** [#{title}](/projects/#{slug}/stories/#{id})"

      _ ->
        "**Project:** [#{project.name}](/projects/#{slug}/requirements)"
    end
  end

  defp start_link(%{satisfied_by: nil}, _slug, _task_info), do: nil

  defp start_link(%{satisfied_by: task_module}, slug, {session_id, task_id}) do
    task_name = task_module |> inspect() |> String.split(".") |> List.last()
    "**Task:** `#{task_name}` — [Start task](/api/projects/#{slug}/sessions/#{session_id}/tasks/#{task_id}/start)"
  end

  defp start_link(%{satisfied_by: task_module}, _slug, nil) do
    task_name = task_module |> inspect() |> String.split(".") |> List.last()
    "**Task:** `#{task_name}` (no active session — start a session first)"
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
