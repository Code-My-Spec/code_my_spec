defmodule CodeMySpecLocalWeb.InitLive do
  @moduledoc """
  Human interface for the project init checklist.

  Generates markdown (same as the LLM API), then renders it as HTML
  via Earmark. One source of truth for both interfaces.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.AgentTasks.Init
  alias CodeMySpecLocalWeb.InitMarkdown

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, working_dir: nil, markdown: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"dir" => dir, "step" => step_id}, _uri, %{assigns: %{live_action: action}} = socket)
      when action in [:show, :prompt] do
    with {:ok, working_dir} <- resolve_dir(dir) do
      {:noreply, load_step(socket, working_dir, step_id)}
    else
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  def handle_params(%{"dir" => dir}, _uri, socket) do
    with {:ok, working_dir} <- resolve_dir(dir) do
      {:noreply, load_index(socket, working_dir)}
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
    <div :if={@error} style="color: #f87171;">
      <h1>Error</h1>
      <p>{@error}</p>
    </div>

    <div :if={@markdown} class="prose prose-invert">
      {raw(CodeMySpecLocalWeb.markdown_to_html(@markdown))}
    </div>
    """
  end

  defp load_index(socket, working_dir) do
    scope = %{cwd: working_dir}
    evaluated = Init.evaluate_all(scope)
    {done, total} = count_progress(evaluated)

    markdown =
      InitMarkdown.index(%{
        evaluated: evaluated,
        title: "Project Init",
        done: done,
        total: total,
        base_path: "/init"
      })

    # Rewrite links to include dir param for LiveView navigation
    markdown = rewrite_links(markdown, working_dir)

    assign(socket,
      working_dir: working_dir,
      markdown: markdown,
      page_title: "Project Init (#{done}/#{total})",
      error: nil
    )
  end

  defp load_step(socket, working_dir, step_id) do
    scope = %{cwd: working_dir}

    case Init.evaluate_one(step_id, scope) do
      {:ok, mod, status} ->
        name = Init.step_name(mod)

        markdown =
          case socket.assigns.live_action do
            :prompt ->
              case mod.command(scope, %{}) do
                {:ok, text} -> "# #{name} — Prompt\n\n```\n#{text}\n```"
                _ -> "# #{name}\n\nNo prompt available."
              end

            :show ->
              show_md = InitMarkdown.show(%{mod: mod, status: status, base_path: "/init"})

              prompt_md =
                if match?({:not_done, _}, status) do
                  case mod.command(scope, %{}) do
                    {:ok, text} -> "\n\n## Instructions\n\n#{text}"
                    _ -> ""
                  end
                else
                  ""
                end

              back = "[← Back to checklist](/init?dir=#{URI.encode_www_form(working_dir)})\n\n"
              back <> show_md <> prompt_md
          end

        assign(socket,
          working_dir: working_dir,
          markdown: markdown,
          page_title: name,
          error: nil
        )

      {:error, :not_found} ->
        assign(socket, error: "Step not found: #{step_id}")
    end
  end

  defp rewrite_links(markdown, working_dir) do
    dir_param = URI.encode_www_form(working_dir)
    String.replace(markdown, ~r/\]\(\/init\/([^)]+)\)/, "](/init/\\1?dir=#{dir_param})")
  end

  defp resolve_dir(dir) do
    expanded = Path.expand(dir)
    if File.dir?(expanded), do: {:ok, find_project_root(expanded)}, else: {:error, "Invalid directory: #{dir}"}
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
