defmodule CodeMySpecLocalWeb.InitLive do
  @moduledoc """
  Human interface for the project init checklist.

  Scoped under `/projects/:project_name/init[/:step]`. The project's
  `local_path` is the working directory the checklist evaluates against.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.AgentTasks.Init
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()

    {:ok,
     assign(socket,
       projects: projects,
       project: nil,
       scope: nil,
       slug: nil,
       steps: [],
       step: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"project_name" => name, "step" => step_id}, _uri, socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} -> load_step(socket, project, scope, step_id)
      {:error, msg} -> {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  def handle_params(%{"project_name" => name}, _uri, socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} -> load_checklist(socket, project, scope)
      {:error, msg} -> {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      page_title={assigns[:page_title] || "Project Init"}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={@step}>
        <div class="mb-4">
          <.link navigate={~p"/projects/#{@slug}/init"} class="btn btn-ghost btn-sm gap-1">
            ← Back to checklist
          </.link>
        </div>

        <div class="flex items-start justify-between gap-4 mb-6">
          <h1 class="text-2xl font-bold">{@step.name}</h1>
          <span :if={@step.status == :done} class="badge badge-success">Done</span>
          <span :if={match?({:not_done, _}, @step.status)} class="badge badge-warning">
            Not done — {elem(@step.status, 1)}
          </span>
        </div>

        <div :if={@step.prompt} class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <div class="flex items-start justify-between gap-3">
              <h2 class="card-title text-lg">Instructions</h2>
              <button
                type="button"
                class="copy-btn btn btn-primary btn-sm"
                data-copy={@step.prompt}
                aria-label="Copy this step's prompt to the clipboard"
              >
                Copy prompt
              </button>
            </div>
            <p class="text-xs opacity-60 mt-1 mb-2">
              Copy this prompt and paste it into Claude Code so the agent can run this step.
            </p>
            <pre class="whitespace-pre-wrap text-sm">{@step.prompt}</pre>
          </div>
        </div>
      </div>

      <div :if={@steps != [] and is_nil(@step)}>
        <div class="mb-6">
          <h1 class="text-3xl font-bold">
            Project Init
            <span class="text-base-content/50 font-normal text-xl">
              ({Enum.count(@steps, & &1.done)}/{length(@steps)})
            </span>
          </h1>
          <p class="text-sm opacity-60 font-mono mt-1">{@scope.cwd}</p>
        </div>

        <ul class="menu bg-base-200 border border-base-300 rounded-box w-full">
          <li :for={step <- @steps}>
            <div class="flex items-center gap-3">
              <span :if={step.done} class="badge badge-success badge-sm">✓</span>
              <span :if={!step.done} class="badge badge-ghost badge-sm">○</span>
              <.link
                :if={!step.done}
                navigate={~p"/projects/#{@slug}/init/#{step.id}"}
                class="link link-primary flex-1"
              >
                {step.name}
              </.link>
              <span :if={step.done} class="flex-1">{step.name}</span>
              <span :if={step.detail} class="text-xs opacity-60">{step.detail}</span>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  # --- handle_params helpers ---

  defp load_checklist(socket, project, scope) do
    steps = Enum.map(Init.evaluate_all(scope), &to_step_summary/1)
    done = Enum.count(steps, & &1.done)
    total = length(steps)

    {:noreply,
     assign(socket,
       project: project,
       scope: scope,
       slug: project_slug(project),
       steps: steps,
       step: nil,
       page_title: "#{project.name} — Init (#{done}/#{total})",
       error: nil
     )}
  end

  defp load_step(socket, project, scope, step_id) do
    case Init.evaluate_one(step_id, scope) do
      {:ok, mod, status} ->
        {:noreply,
         assign(socket,
           project: project,
           scope: scope,
           slug: project_slug(project),
           step: %{
             name: Init.step_name(mod),
             id: Init.step_id(mod),
             status: status,
             prompt: step_prompt(mod, scope, status)
           },
           page_title: "#{project.name} — #{Init.step_name(mod)}",
           error: nil
         )}

      {:error, :not_found} ->
        {:noreply, assign(socket, project: project, scope: scope, slug: project_slug(project), error: "Step not found: #{step_id}")}
    end
  end

  defp to_step_summary({mod, status}) do
    %{
      id: Init.step_id(mod),
      name: Init.step_name(mod),
      done: status == :done,
      detail: step_detail(status)
    }
  end

  defp step_detail({:not_done, detail}), do: detail
  defp step_detail(:done), do: nil

  defp step_prompt(mod, scope, {:not_done, _}) do
    case mod.command(scope, %{}) do
      {:ok, text} -> text
      _ -> nil
    end
  end

  defp step_prompt(_mod, _scope, :done), do: nil

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
