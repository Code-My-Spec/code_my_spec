defmodule CodeMySpecLocalWeb.NextTaskMarkdown do
  @moduledoc """
  Markdown rendering for the next actionable task.

  Shared by both the LLM API (plain text) and the human UI (rendered via MDEx).
  """

  alias CodeMySpec.Repo

  @doc """
  Build markdown for a next-task result.

  When a task_info tuple is provided, includes start-task and evaluation instructions.
  """
  def render(result, scope, project, task_info \\ nil)

  def render({:ok, requirement}, _scope, project, task_info) do
    requirement = Repo.preload(requirement, [:component, :story])
    slug = project_slug(project)

    sections = [
      back_link(slug),
      header(requirement),
      entity_context(requirement, slug, project),
      start_section(requirement, slug, task_info),
      validation_section(requirement, slug, task_info)
    ]

    Enum.reject(sections, &is_nil/1) |> Enum.join("\n\n")
  end

  def render(:complete, _scope, project, _task_info) do
    slug = project_slug(project)
    "[← Back to requirements](/projects/#{slug}/requirements)\n\n# All requirements satisfied\n\nNo actionable tasks remain."
  end

  def render({:error, reason}, _scope, project, _task_info) do
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

  # -- Start section ---------------------------------------------------------

  defp start_section(%{satisfied_by: nil}, _slug, _task_info), do: nil

  defp start_section(%{satisfied_by: task_module, execution_type: execution_type}, slug, {session_id, task_id}) do
    task_name = task_module |> inspect() |> String.split(".") |> List.last()
    start_url = "/api/projects/#{slug}/sessions/#{session_id}/tasks/#{task_id}/start"

    execution_note =
      case execution_type do
        :sub_agent ->
          "**Execution:** This task should be delegated to a sub-agent. Start it, then pass the prompt."

        _ ->
          "**Execution:** You are the agent responsible for this task. Start it to get the prompt."
      end

    "**Task:** `#{task_name}` — [Start task](#{start_url})\n\n#{execution_note}"
  end

  defp start_section(%{satisfied_by: task_module, execution_type: execution_type}, _slug, nil) do
    task_name = task_module |> inspect() |> String.split(".") |> List.last()
    exec_label = if execution_type == :sub_agent, do: "sub-agent", else: "main agent"
    "**Task:** `#{task_name}` | **Execution:** #{exec_label}"
  end

  # -- Validation section ----------------------------------------------------

  defp validation_section(%{validation_type: :manual}, slug, {session_id, task_id}) do
    evaluate_url = "/api/projects/#{slug}/sessions/#{session_id}/tasks/#{task_id}/evaluate"

    "**Validation:** Manual — the task will not be marked complete automatically. " <>
      "When done, [evaluate the task](#{evaluate_url})."
  end

  defp validation_section(%{validation_type: :automatic}, _slug, {_session_id, _task_id}) do
    "**Validation:** Automatic. The stop hook will evaluate this task when the agent finishes."
  end

  defp validation_section(_, _, _), do: nil

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
