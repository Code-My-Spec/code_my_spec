defmodule CodeMySpecLocalWeb.InitLive do
  @moduledoc """
  Human interface for the project init checklist.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.AgentTasks.Init
  alias CodeMySpec.Projects

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()

    {:ok,
     assign(socket,
       projects: projects,
       project: nil,
       working_dir: nil,
       steps: [],
       step: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"dir" => dir, "step" => step_id}, _uri, socket) do
    with {:ok, working_dir} <- resolve_dir(dir) do
      scope = %{cwd: working_dir}

      case Init.evaluate_one(step_id, scope) do
        {:ok, mod, status} ->
          prompt =
            case status do
              {:not_done, _} ->
                case mod.command(scope, %{}) do
                  {:ok, text} -> text
                  _ -> nil
                end

              :done ->
                nil
            end

          {:noreply,
           assign(socket,
             working_dir: working_dir,
             step: %{name: Init.step_name(mod), id: Init.step_id(mod), status: status, prompt: prompt},
             page_title: Init.step_name(mod),
             error: nil
           )}

        {:error, :not_found} ->
          {:noreply, assign(socket, error: "Step not found: #{step_id}")}
      end
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"dir" => dir}, _uri, socket) do
    with {:ok, working_dir} <- resolve_dir(dir) do
      scope = %{cwd: working_dir}
      evaluated = Init.evaluate_all(scope)

      steps =
        Enum.map(evaluated, fn {mod, status} ->
          %{
            id: Init.step_id(mod),
            name: Init.step_name(mod),
            done: status == :done,
            detail:
              case status do
                {:not_done, detail} -> detail
                :done -> nil
              end
          }
        end)

      done = Enum.count(steps, & &1.done)
      total = length(steps)

      {:noreply,
       assign(socket,
         working_dir: working_dir,
         steps: steps,
         step: nil,
         page_title: "Project Init (#{done}/#{total})",
         error: nil
       )}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, error: "Missing ?dir= parameter")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={nil}
      page_title={assigns[:page_title] || "Project Init"}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={@step}>
        <div class="mb-4">
          <.link navigate={"/init?dir=#{URI.encode_www_form(@working_dir)}"} class="btn btn-ghost btn-sm gap-1">
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
            <h2 class="card-title text-lg">Instructions</h2>
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
          <p class="text-sm opacity-60 font-mono mt-1">{@working_dir}</p>
        </div>

        <ul class="menu bg-base-200 border border-base-300 rounded-box w-full">
          <li :for={step <- @steps}>
            <div class="flex items-center gap-3">
              <span :if={step.done} class="badge badge-success badge-sm">✓</span>
              <span :if={!step.done} class="badge badge-ghost badge-sm">○</span>
              <.link
                :if={!step.done}
                navigate={"/init/#{step.id}?dir=#{URI.encode_www_form(@working_dir)}"}
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

  defp resolve_dir(dir) do
    expanded = Path.expand(dir)

    if File.dir?(expanded),
      do: {:ok, find_project_root(expanded)},
      else: {:error, "Invalid directory: #{dir}"}
  end

  defp find_project_root(dir) do
    cond do
      File.exists?(Path.join(dir, "mix.exs")) -> dir
      dir == "/" or dir == Path.dirname(dir) -> dir
      true -> find_project_root(Path.dirname(dir))
    end
  end
end
