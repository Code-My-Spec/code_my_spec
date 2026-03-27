defmodule CodeMySpecLocalWeb.InitLive do
  @moduledoc """
  Human interface for the project init checklist.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.AgentTasks.Init

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, working_dir: nil, steps: [], step: nil, error: nil)}
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
    <div :if={@error} class="alert alert-error">
      <p>{@error}</p>
    </div>

    <div :if={@step} class="prose prose-invert max-w-none">
      <h1>{@step.name}</h1>
      <p :if={@step.status == :done} class="text-success">Done</p>
      <p :if={match?({:not_done, _}, @step.status)} class="text-warning">
        Not done — {elem(@step.status, 1)}
      </p>
      <div :if={@step.prompt}>
        <h2>Instructions</h2>
        <pre class="whitespace-pre-wrap text-sm">{@step.prompt}</pre>
      </div>
      <.link navigate={"/init?dir=#{URI.encode_www_form(@working_dir)}"} class="link">
        ← Back to checklist
      </.link>
    </div>

    <div :if={@steps != [] and is_nil(@step)} class="prose prose-invert max-w-none">
      <h1>Project Init ({Enum.count(@steps, & &1.done)}/{length(@steps)})</h1>
      <ul>
        <li :for={step <- @steps}>
          <span :if={step.done} class="text-success">[x]</span>
          <span :if={!step.done}>[ ]</span>
          <.link
            :if={!step.done}
            navigate={"/init/#{step.id}?dir=#{URI.encode_www_form(@working_dir)}"}
            class="link"
          >
            {step.name}
          </.link>
          <span :if={step.done}>{step.name}</span>
          <span :if={step.detail} class="text-base-content/50 text-sm"> — {step.detail}</span>
        </li>
      </ul>
    </div>
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
