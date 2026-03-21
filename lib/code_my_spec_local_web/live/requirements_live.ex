defmodule CodeMySpecLocalWeb.RequirementsLive do
  @moduledoc """
  Human interface for project requirements status.

  - Index: sorted checklist of all project requirements
  - Show: command output (instructions) + child checklist if scope: :children
  - Child: individual child step's command output
  - Prompt: raw prompt text for LLM consumption
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Setup.SetupSteps
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       project: nil,
       scope: nil,
       requirements: [],
       requirement: nil,
       command_text: nil,
       prompt_text: nil,
       child_step: nil,
       actionable: %{},
       error: nil
     )}
  end

  # --- Handle params ---

  @impl true
  def handle_params(%{"project_name" => name, "name" => req_name, "child_id" => child_id}, _uri, %{assigns: %{live_action: :child}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      project = Repo.preload(project, :requirements)
      requirement = Enum.find(project.requirements, &(&1.name == req_name))
      step = Enum.find(SetupSteps.all(), &(&1.id == child_id))

      if requirement && step do
        command_text = generate_prompt(step.module, scope, project)

        {:noreply,
         assign(socket,
           project: project,
           scope: scope,
           requirement: requirement,
           child_step: step,
           command_text: command_text,
           error: nil
         )}
      else
        {:noreply, assign(socket, error: "Step not found: #{child_id}")}
      end
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name, "name" => req_name}, _uri, %{assigns: %{live_action: :prompt}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      project = Repo.preload(project, :requirements)
      requirement = Enum.find(project.requirements, &(&1.name == req_name))

      if requirement && requirement.satisfied_by do
        prompt_text = generate_prompt(requirement.satisfied_by, scope, project)

        {:noreply,
         assign(socket,
           project: project,
           scope: scope,
           requirement: requirement,
           prompt_text: prompt_text,
           error: nil
         )}
      else
        {:noreply, assign(socket, error: "No prompt available for: #{req_name}")}
      end
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name, "name" => req_name}, _uri, %{assigns: %{live_action: :show}} = socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      project = Repo.preload(project, :requirements)
      requirement = Enum.find(project.requirements, &(&1.name == req_name))

      if requirement do
        {:noreply,
         assign(socket,
           project: project,
           scope: scope,
           requirement: requirement,
           error: nil
         )}
      else
        {:noreply, assign(socket, error: "Requirement not found: #{req_name}")}
      end
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      project = Repo.preload(project, :requirements)
      requirements = project.requirements || []
      project = %{project | requirements: requirements}
      actionable = Requirements.next_actionable(scope, project)

      {:noreply,
       assign(socket,
         project: project,
         scope: scope,
         requirements: requirements,
         actionable: actionable,
         requirement: nil,
         error: nil
       )}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} style="color: #f87171; padding: 24px;">
      <h1>Error</h1>
      <p>{@error}</p>
    </div>

    <%!-- Index: all project requirements --%>
    <div :if={!@error && @project && @live_action == :index}>
      <h1>{@project.name || "Project"} — Requirements</h1>
      <.requirements_progress requirements={@requirements} />
      <.requirements_list requirements={@requirements} project={@project} actionable={@actionable} />
    </div>

    <%!-- Show: requirement detail with command output + child checklist --%>
    <div :if={!@error && @project && @live_action == :show && @requirement}>
      <a href={"/projects/#{project_slug(@project)}/requirements"} class="back-link">&larr; Back to requirements</a>
      <h1>{@requirement.name}</h1>
      <p style="color: #94a3b8; margin-bottom: 8px;">{@requirement.description}</p>

      <div style="margin-bottom: 24px;">
        <span class={if @requirement.satisfied, do: "status-done", else: "status-actionable"}>
          {if @requirement.satisfied, do: "Satisfied", else: "Not satisfied"}
        </span>
        <span :if={@requirement.score} style="color: #94a3b8; margin-left: 8px;">
          (score: {Float.round(@requirement.score, 2)})
        </span>
      </div>

      <%!-- Child checklist (for scope: :children requirements) --%>
      <.child_checklist
        :if={get_checklist(@requirement)}
        requirement={@requirement}
        project={@project}
      />

      <div :if={@requirement.checked_at} style="color: #64748b; font-size: 13px; margin-top: 16px;">
        Last checked: {Calendar.strftime(@requirement.checked_at, "%Y-%m-%d %H:%M:%S UTC")}
      </div>
    </div>

    <%!-- Child: individual child step detail --%>
    <div :if={!@error && @project && @live_action == :child && @child_step}>
      <a href={"/projects/#{project_slug(@project)}/requirements/#{@requirement.name}"} class="back-link">&larr; Back to {@requirement.name}</a>
      <h1>{@child_step.name}</h1>

      <pre :if={@command_text}>{@command_text}</pre>
      <p :if={!@command_text} style="color: #94a3b8;">No instructions available.</p>
    </div>

    <%!-- Prompt: raw text for LLM --%>
    <div :if={!@error && @project && @live_action == :prompt && @requirement}>
      <a href={"/projects/#{project_slug(@project)}/requirements/#{@requirement.name}"} class="back-link">&larr; Back to requirement</a>
      <h1>{@requirement.name} — Prompt</h1>
      <pre>{@prompt_text}</pre>
    </div>
    """
  end

  # --- Components ---

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
          <a href={"/projects/#{project_slug(@project)}/requirements/#{req.name}"}>{req.name}</a>
          <span class="detail">{req.description}</span>
        </td>
      </tr>
    </table>
    """
  end

  defp child_checklist(assigns) do
    items = get_checklist(assigns.requirement) || []
    done = Enum.count(items, &(get_field(&1, "satisfied")))
    total = length(items)
    assigns = assign(assigns, items: items, done: done, total: total)

    ~H"""
    <div style="margin-top: 24px;">
      <h2>Steps</h2>
      <.progress done={@done} total={@total} />
      <table class="checklist">
        <tr :for={item <- @items} class={if get_field(item, "satisfied"), do: "done", else: "actionable"}>
          <td class="icon">{if get_field(item, "satisfied"), do: raw("&#10003;"), else: raw("&#9744;")}</td>
          <td>
            <a href={"/projects/#{project_slug(@project)}/requirements/#{@requirement.name}/#{get_field(item, "id")}"}>{get_field(item, "name")}</a>
            <span :if={detail = get_field(item, "detail")} class="detail">{detail}</span>
          </td>
        </tr>
      </table>
    </div>
    """
  end

  # --- Helpers ---

  defp get_checklist(%{details: details}) do
    details["checklist"] || Map.get(details, :checklist)
  end

  defp get_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    _ -> Map.get(map, key)
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

  defp load_project_and_scope(name) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:ok, project, scope}
    end
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
