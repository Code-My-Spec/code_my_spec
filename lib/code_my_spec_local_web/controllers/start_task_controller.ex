defmodule CodeMySpecLocalWeb.StartTaskController do
  @moduledoc """
  Activates a prepared task and returns the prompt as markdown.

  This is the gate — the agent must call this to see the prompt.
  Transitions the task from :prepared → :active.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Requirements
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  def start(conn, %{"session_id" => session_id, "task_id" => task_id}) do
    scope = conn.assigns.current_scope
    agent_id = get_agent_id(conn)

    case Sessions.get_session(scope, session_id) do
      nil ->
        conn |> put_status(404) |> text("Session not found: #{session_id}")

      session ->
        handle_task(conn, scope, session, task_id, agent_id)
    end
  end

  defp get_agent_id(conn) do
    (conn.body_params || %{})["agent_id"] ||
      (conn.query_params || %{})["agent_id"]
  end

  defp handle_task(conn, scope, session, task_id, agent_id) do
    case Session.find_task(session, task_id) do
      nil ->
        conn |> put_status(404) |> text("Task not found: #{task_id}")

      %{status: :active} = task ->
        if agent_id && is_nil(task.agent_id) do
          Sessions.assign_agent(scope, session, task_id, agent_id)
        end

        text(conn, generate_prompt(task, scope))

      %{status: :prepared} = task ->
        case Sessions.activate_task(scope, session, task_id, agent_id) do
          {:ok, _updated} ->
            text(conn, generate_prompt(task, scope))

          {:error, reason} ->
            conn |> put_status(422) |> text("Failed to activate task: #{inspect(reason)}")
        end

      %{status: other} ->
        conn |> put_status(409) |> text("Task is #{other}, cannot start")
    end
  end

  defp generate_prompt(task, scope) do
    task_module = task.session_type

    if is_nil(task_module) do
      "No task module configured for this task."
    else
      prompt =
        case task_module.command(scope, task) do
          {:ok, text} -> text
          {:error, reason} -> "Error generating prompt: #{inspect(reason)}"
        end

      prompt <> checklist_section(task, scope)
    end
  rescue
    error -> "Error: #{inspect(error)}"
  end

  defp checklist_section(%{requirement_id: nil}, _scope), do: ""

  defp checklist_section(%{requirement_id: req_id}, _scope) do
    case Requirements.get_requirement(req_id) do
      nil -> ""
      requirement -> render_checklist(requirement)
    end
  end

  defp render_checklist(requirement) do
    checklist = get_in(requirement.details, ["checklist"]) || []

    if checklist == [] do
      ""
    else
      done = Enum.count(checklist, fn item -> item["satisfied"] || false end)
      total = length(checklist)

      slug = requirement_slug(requirement)

      lines =
        Enum.map_join(checklist, "\n", fn item ->
          name = item["name"]
          id = item["id"]
          satisfied = item["satisfied"] || false
          detail = item["detail"]

          check = if satisfied, do: "[x]", else: "[ ]"
          link = "[#{name}](/api/projects/#{slug}/requirements/#{requirement.name}/#{id})"
          detail_text = if detail && !satisfied, do: " — #{detail}", else: ""

          "- #{check} #{link}#{detail_text}"
        end)

      "\n\n## Steps (#{done}/#{total})\n\n#{lines}\n"
    end
  end

  defp requirement_slug(requirement) do
    case requirement.project do
      %{name: name} when is_binary(name) ->
        name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

      _ ->
        "project"
    end
  end
end
