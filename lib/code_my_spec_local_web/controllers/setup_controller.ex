defmodule CodeMySpecLocalWeb.SetupController do
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Setup.SetupSteps

  def index(conn, _params) do
    working_dir = conn.assigns.working_dir
    scope = conn.assigns[:current_scope] || %{cwd: working_dir}
    evaluated = SetupSteps.evaluate_all(scope, working_dir)
    {done, total} = count_progress(evaluated)

    case conn.assigns.format do
      :markdown ->
        lines =
          Enum.map(evaluated, fn {step, status} ->
            case status do
              :done -> "- [x] #{step.name}"
              :blocked -> "- [ ] #{step.name} (blocked)"
              {:not_done, _} -> "- [ ] [#{step.name}](/setup/#{step.id})"
            end
          end)

        text(conn, "# Project Setup (#{done}/#{total})\n\n#{Enum.join(lines, "\n")}\n")

      :html ->
        conn
        |> put_root_layout(html: {CodeMySpecLocalWeb.Layouts, :root})
        |> put_view(CodeMySpecLocalWeb.InitHTML)
        |> assign(:page_title, "Project Setup (#{done}/#{total})")
        |> assign(:evaluated, evaluated)
        |> assign(:done, done)
        |> assign(:total, total)
        |> assign(:base_path, "/setup")
        |> assign(:title, "Project Setup")
        |> assign(:dir_param, URI.encode_www_form(working_dir))
        |> render(:index)
    end
  end

  def show(conn, %{"step" => step_id}) do
    working_dir = conn.assigns.working_dir
    scope = conn.assigns[:current_scope] || %{cwd: working_dir}

    case SetupSteps.evaluate_one(step_id, scope, working_dir) do
      {:ok, step, status} ->
        case conn.assigns.format do
          :markdown ->
            render_markdown_step(conn, step, status)

          :html ->
            {:ok, prompt_text} =
              if match?({:not_done, _}, status),
                do: step.module.command(scope, %{}),
                else: {:ok, nil}

            conn
            |> put_root_layout(html: {CodeMySpecLocalWeb.Layouts, :root})
            |> put_view(CodeMySpecLocalWeb.InitHTML)
            |> assign(:page_title, step.name)
            |> assign(:step, step)
            |> assign(:status, status)
            |> assign(:prompt_text, prompt_text)
            |> assign(:base_path, "/setup")
            |> assign(:dir_param, URI.encode_www_form(working_dir))
            |> render(:show)
        end

      {:error, :not_found} ->
        conn |> put_status(404) |> text("Step not found: #{step_id}")
    end
  end

  def prompt(conn, %{"step" => step_id}) do
    working_dir = conn.assigns.working_dir
    scope = conn.assigns[:current_scope] || %{cwd: working_dir}

    case SetupSteps.evaluate_one(step_id, scope, working_dir) do
      {:ok, step, _} ->
        {:ok, prompt_text} = step.module.command(scope, %{})
        text(conn, prompt_text)

      {:error, :not_found} ->
        conn |> put_status(404) |> text("Step not found: #{step_id}")
    end
  end

  defp render_markdown_step(conn, step, status) do
    status_line =
      case status do
        :done -> "Status: done"
        :blocked -> "Status: blocked (prerequisites: #{Enum.join(step.prereqs, ", ")})"
        {:not_done, detail} -> "Status: not done — #{detail}"
      end

    prompt_link =
      case status do
        {:not_done, _} -> "\n\nPrompt: [/setup/#{step.id}/prompt](/setup/#{step.id}/prompt)"
        _ -> ""
      end

    text(conn, "# #{step.name}\n\n#{status_line}#{prompt_link}\n")
  end

  defp count_progress(evaluated) do
    done = Enum.count(evaluated, fn {_, s} -> s == :done end)
    {done, length(evaluated)}
  end
end
