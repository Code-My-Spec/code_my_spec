defmodule CodeMySpecLocalWeb.SetupLive do
  @moduledoc """
  Human interface for the project setup checklist.

  Shows real-time progress of setup steps (post-init, project exists).
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Setup.SetupSteps
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       evaluated: [],
       done: 0,
       total: 0,
       working_dir: nil,
       error: nil,
       step: nil,
       status: nil,
       prompt_text: nil
     )}
  end

  @impl true
  def handle_params(%{"dir" => dir, "step" => step_id}, _uri, %{assigns: %{live_action: action}} = socket)
      when action in [:show, :prompt] do
    with {:ok, working_dir, scope} <- resolve_scope(dir) do
      {:noreply, load_step_data(socket, working_dir, scope, step_id)}
    else
      {:error, message} -> {:noreply, assign(socket, error: message)}
    end
  end

  def handle_params(%{"dir" => dir}, _uri, socket) do
    with {:ok, working_dir, scope} <- resolve_scope(dir) do
      {:noreply, load_index_data(socket, working_dir, scope)}
    else
      {:error, message} -> {:noreply, assign(socket, error: message)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, error: "Missing ?dir= parameter")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} style="color: #f87171; padding: 24px;">
      <h1>Error</h1>
      <p>{@error}</p>
    </div>

    <div :if={!@error && @working_dir && @live_action == :index}>
      <h1>Project Setup</h1>
      <.progress done={@done} total={@total} />
      <.checklist evaluated={@evaluated} base_path="/setup" dir_param={URI.encode_www_form(@working_dir)} />
    </div>

    <div :if={!@error && @working_dir && @live_action == :show && @step}>
      <a href={"/setup?dir=#{URI.encode_www_form(@working_dir)}"} class="back-link">&larr; Back to checklist</a>
      <h1>{@step.name}</h1>

      <div style="margin-bottom: 24px;">
        <.step_status status={@status} step={@step} />
      </div>

      <div :if={@prompt_text}>
        <h2>Instructions</h2>
        <pre>{@prompt_text}</pre>
        <a href={"/setup/#{@step.id}/prompt?dir=#{URI.encode_www_form(@working_dir)}"} style="display: inline-block; margin-top: 12px; font-size: 13px;">
          View raw prompt
        </a>
      </div>
    </div>

    <div :if={!@error && @working_dir && @live_action == :prompt && @step}>
      <a href={"/setup/#{@step.id}?dir=#{URI.encode_www_form(@working_dir)}"} class="back-link">&larr; Back to step</a>
      <h1>{@step.name} — Prompt</h1>
      <pre>{@prompt_text || "No prompt available (step may be done or blocked)"}</pre>
    </div>
    """
  end

  defp step_status(%{status: :done} = assigns) do
    ~H"""
    <span class="status-done">Done</span>
    """
  end

  defp step_status(%{status: :blocked} = assigns) do
    ~H"""
    <span class="status-blocked">Blocked</span> — waiting on: {Enum.join(@step.prereqs, ", ")}
    """
  end

  defp step_status(%{status: {:not_done, detail}} = assigns) do
    assigns = assign(assigns, :detail, detail)

    ~H"""
    <span class="status-actionable">Not done</span> — {@detail}
    """
  end

  defp resolve_scope(dir) do
    expanded = Path.expand(dir)

    cond do
      not File.dir?(expanded) ->
        {:error, "Invalid directory: #{dir}"}

      true ->
        working_dir = find_project_root(expanded)

        scope =
          case Scope.from_local_config(working_dir) do
            {:ok, scope} -> scope
            _ -> %{cwd: working_dir}
          end

        {:ok, working_dir, scope}
    end
  end

  defp load_index_data(socket, working_dir, scope) do
    evaluated = SetupSteps.evaluate_all(scope, working_dir)
    {done, total} = count_progress(evaluated)

    assign(socket,
      working_dir: working_dir,
      evaluated: evaluated,
      done: done,
      total: total,
      page_title: "Project Setup (#{done}/#{total})",
      step: nil,
      status: nil,
      prompt_text: nil,
      error: nil
    )
  end

  defp load_step_data(socket, working_dir, scope, step_id) do
    case SetupSteps.evaluate_one(step_id, scope, working_dir) do
      {:ok, step, status} ->
        prompt_text =
          if match?({:not_done, _}, status) do
            {:ok, text} = step.module.command(scope, %{})
            text
          end

        assign(socket,
          working_dir: working_dir,
          step: step,
          status: status,
          prompt_text: prompt_text,
          page_title: step.name,
          error: nil
        )

      {:error, :not_found} ->
        assign(socket, error: "Step not found: #{step_id}")
    end
  end

  defp count_progress(evaluated) do
    done = Enum.count(evaluated, fn {_, s} -> s == :done end)
    {done, length(evaluated)}
  end

  defp find_project_root(dir) do
    cond do
      File.exists?(Path.join(dir, "mix.exs")) -> dir
      dir == "/" or dir == Path.dirname(dir) -> dir
      true -> find_project_root(Path.dirname(dir))
    end
  end
end
