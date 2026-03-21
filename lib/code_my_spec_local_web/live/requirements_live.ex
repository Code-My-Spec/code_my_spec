defmodule CodeMySpecLocalWeb.RequirementsLive do
  @moduledoc """
  Human interface for project requirements status.

  Shows all requirements for a project with their satisfaction status,
  grouped by artifact type. Replaces the static .code_my_spec/status/ files.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementDefinitionData

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       project: nil,
       requirements: [],
       requirement: nil,
       prompt_text: nil,
       actionable: %{},
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"project_id" => project_id, "name" => name}, _uri, %{assigns: %{live_action: :prompt}} = socket) do
    with {:ok, scope} <- resolve_scope_for_project(project_id) do
      project = Repo.preload(scope.active_project, :requirements)
      requirement = Enum.find(project.requirements, &(&1.name == name))

      if requirement && requirement.satisfied_by do
        prompt_text = generate_prompt(requirement.satisfied_by, scope, project)

        {:noreply,
         assign(socket,
           project: project,
           requirement: requirement,
           prompt_text: prompt_text,
           error: nil
         )}
      else
        {:noreply, assign(socket, error: "No prompt available for: #{name}")}
      end
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_id" => project_id, "name" => name}, _uri, %{assigns: %{live_action: :show}} = socket) do
    with {:ok, scope} <- resolve_scope_for_project(project_id) do
      project = Repo.preload(scope.active_project, :requirements)
      requirement = Enum.find(project.requirements, &(&1.name == name))

      if requirement do
        {:noreply,
         assign(socket,
           project: project,
           requirement: requirement,
           error: nil
         )}
      else
        {:noreply, assign(socket, error: "Requirement not found: #{name}")}
      end
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_id" => project_id}, _uri, socket) do
    with {:ok, scope} <- resolve_scope_for_project(project_id) do
      project = Repo.preload(scope.active_project, :requirements)
      requirements = load_requirements(scope, project)
      project = %{project | requirements: requirements}
      actionable = Requirements.next_actionable(scope, project)

      {:noreply,
       assign(socket,
         project: project,
         requirements: requirements,
         actionable: actionable,
         requirement: nil,
         error: nil
       )}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} style="color: #f87171; padding: 24px;">
      <h1>Error</h1>
      <p>{@error}</p>
    </div>

    <div :if={!@error && @project && @live_action == :index}>
      <h1>{@project.name || "Project"} — Requirements</h1>
      <.requirements_progress requirements={@requirements} />
      <.requirements_list requirements={@requirements} project={@project} actionable={@actionable} />
    </div>

    <div :if={!@error && @project && @live_action == :show && @requirement}>
      <a href={"/projects/#{@project.id}/requirements"} class="back-link">&larr; Back to requirements</a>
      <h1>{@requirement.name}</h1>
      <p style="color: #94a3b8; margin-bottom: 16px;">{@requirement.description}</p>

      <div style="margin-bottom: 24px;">
        <span class={if @requirement.satisfied, do: "status-done", else: "status-actionable"}>
          {if @requirement.satisfied, do: "Satisfied", else: "Not satisfied"}
        </span>
        <span :if={@requirement.score} style="color: #94a3b8; margin-left: 8px;">
          (score: {Float.round(@requirement.score, 2)})
        </span>
      </div>

      <div :if={@requirement.details != %{}} style="margin-bottom: 24px;">
        <h2>Details</h2>
        <pre>{Jason.encode!(@requirement.details, pretty: true)}</pre>
      </div>

      <div :if={@requirement.satisfied_by} style="margin-bottom: 24px;">
        <h2>Satisfied by</h2>
        <code>{inspect(@requirement.satisfied_by)}</code>
      </div>

      <div :if={@requirement.checked_at} style="color: #64748b; font-size: 13px;">
        Last checked: {Calendar.strftime(@requirement.checked_at, "%Y-%m-%d %H:%M:%S UTC")}
      </div>

      <a :if={@requirement.satisfied_by} href={"/projects/#{@project.id}/requirements/#{@requirement.name}/prompt"} style="display: inline-block; margin-top: 12px;">
        View prompt &rarr;
      </a>
    </div>

    <div :if={!@error && @project && @live_action == :prompt && @requirement}>
      <a href={"/projects/#{@project.id}/requirements/#{@requirement.name}"} class="back-link">&larr; Back to requirement</a>
      <h1>{@requirement.name} — Prompt</h1>
      <p style="color: #94a3b8; margin-bottom: 16px;">
        Generated by <code>{inspect(@requirement.satisfied_by)}</code>
      </p>
      <pre>{@prompt_text}</pre>
    </div>
    """
  end

  defp requirements_progress(assigns) do
    total = length(assigns.requirements)
    satisfied = Enum.count(assigns.requirements, & &1.satisfied)
    pct = if total > 0, do: round(satisfied / total * 100), else: 0
    assigns = assign(assigns, satisfied: satisfied, total: total, pct: pct)

    ~H"""
    <div class="subtitle">{@satisfied} of {@total} requirements satisfied</div>
    <div class="progress"><div class="progress-bar" style={"width: #{@pct}%"}></div></div>
    """
  end

  defp requirements_list(assigns) do
    # Sort by definition order (prerequisite/dependency order)
    definition_order =
      RequirementDefinitionData.project_requirements()
      |> Enum.with_index()
      |> Map.new(fn {defn, idx} -> {defn.name, idx} end)

    sorted =
      assigns.requirements
      |> Enum.sort_by(fn req -> Map.get(definition_order, req.name, 999) end)

    actionable_names =
      assigns.actionable
      |> Map.values()
      |> List.flatten()
      |> MapSet.new(& &1.name)

    assigns = assign(assigns, sorted: sorted, actionable_names: actionable_names)

    ~H"""
    <table class="checklist">
      <tr :for={req <- @sorted} class={if req.satisfied, do: "done", else: if(MapSet.member?(@actionable_names, req.name), do: "actionable", else: "blocked")}>
        <td class="icon">{if req.satisfied, do: raw("&#10003;"), else: raw("&#9744;")}</td>
        <td>
          <a href={"/projects/#{@project.id}/requirements/#{req.name}"}>{req.name}</a>
          <span class="detail">{req.description}</span>
        </td>
      </tr>
    </table>
    """
  end

  defp generate_prompt(task_module, scope, project) do
    session = %{project: project}

    case task_module.command(scope, session) do
      {:ok, prompt} -> prompt
      {:error, reason} -> "Error generating prompt: #{inspect(reason)}"
      prompt when is_binary(prompt) -> prompt
    end
  rescue
    error -> "Error: #{inspect(error)}"
  end

  defp load_requirements(_scope, project) do
    project.requirements || []
  end

  defp resolve_scope_for_project(project_id) do
    case Repo.get(CodeMySpec.Projects.Project, project_id) do
      nil ->
        {:error, "Project not found: #{project_id}"}

      project ->
        # Minimal scope — no user/account needed for local requirements display
        {:ok,
         %CodeMySpec.Users.Scope{
           active_project: project,
           active_project_id: project.id
         }}
    end
  end
end
