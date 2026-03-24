defmodule CodeMySpec.LocalServer.Controllers.SetupController do
  @moduledoc """
  Serves init and setup checklists with per-step prompts.

  Content-negotiated:
  - Header (X-Working-Dir) → markdown with links
  - Query param (?dir=) → HTML page
  """

  import Plug.Conn

  alias CodeMySpec.AgentTasks.Init
  alias CodeMySpec.AgentTasks.ProjectSetup

  # === Init routes (pre-project-ID) ===

  def index(conn) do
    working_dir = conn.assigns[:working_dir]
    scope = %{cwd: working_dir}
    evaluated = Init.evaluate_all(scope)
    render_list(conn, evaluated, working_dir, "/init", "Project Init", &Init.step_id/1, &Init.step_name/1)
  end

  def show(conn) do
    working_dir = conn.assigns[:working_dir]
    scope = %{cwd: working_dir}
    step_id = conn.path_params["step"]

    case Init.evaluate_one(step_id, scope) do
      {:ok, mod, status} -> render_step(conn, mod, status, working_dir, scope, "/init", &Init.step_id/1, &Init.step_name/1)
      {:error, :not_found} -> not_found(conn, step_id)
    end
  end

  def prompt(conn) do
    working_dir = conn.assigns[:working_dir]
    scope = %{cwd: working_dir}
    step_id = conn.path_params["step"]

    case Init.evaluate_one(step_id, scope) do
      {:ok, mod, _} -> render_prompt(conn, mod, scope)
      {:error, :not_found} -> not_found(conn, step_id)
    end
  end

  # === Setup routes (post-init, project exists) ===

  def setup_index(conn) do
    working_dir = conn.assigns[:working_dir]
    scope = conn.assigns[:current_scope] || %{cwd: working_dir}
    evaluated = evaluate_setup_steps(scope)
    render_list(conn, evaluated, working_dir, "/setup", "Project Setup", &ProjectSetup.step_id/1, &ProjectSetup.step_name/1)
  end

  def setup_show(conn) do
    working_dir = conn.assigns[:working_dir]
    scope = conn.assigns[:current_scope] || %{cwd: working_dir}
    step_id = conn.path_params["step"]

    case find_and_evaluate_setup_step(step_id, scope) do
      {:ok, mod, status} -> render_step(conn, mod, status, working_dir, scope, "/setup", &ProjectSetup.step_id/1, &ProjectSetup.step_name/1)
      {:error, :not_found} -> not_found(conn, step_id)
    end
  end

  def setup_prompt(conn) do
    working_dir = conn.assigns[:working_dir]
    scope = conn.assigns[:current_scope] || %{cwd: working_dir}
    step_id = conn.path_params["step"]

    case find_and_evaluate_setup_step(step_id, scope) do
      {:ok, mod, _} -> render_prompt(conn, mod, scope)
      {:error, :not_found} -> not_found(conn, step_id)
    end
  end

  # === Setup step helpers ===

  defp evaluate_setup_steps(scope) do
    Enum.map(ProjectSetup.setup_steps(), fn mod ->
      status =
        case mod.evaluate(scope, %{}) do
          {:ok, :valid} -> :done
          {:ok, :invalid, detail} -> {:not_done, detail}
          _ -> {:not_done, "unknown"}
        end

      {mod, status}
    end)
  end

  defp find_and_evaluate_setup_step(step_id, scope) do
    case ProjectSetup.find_step(step_id) do
      nil -> {:error, :not_found}
      mod ->
        status =
          case mod.evaluate(scope, %{}) do
            {:ok, :valid} -> :done
            {:ok, :invalid, detail} -> {:not_done, detail}
            _ -> {:not_done, "unknown"}
          end

        {:ok, mod, status}
    end
  end

  # === Shared rendering ===

  defp render_list(conn, evaluated, working_dir, base_path, title, id_fn, name_fn) do
    if conn.assigns[:working_dir_source] == :query_param do
      render_html_checklist(conn, evaluated, working_dir, base_path, title, id_fn, name_fn)
    else
      render_markdown_checklist(conn, evaluated, base_path, title, id_fn, name_fn)
    end
  end

  defp render_step(conn, mod, status, working_dir, scope, base_path, id_fn, name_fn) do
    if conn.assigns[:working_dir_source] == :query_param do
      render_html_step(conn, mod, status, working_dir, scope, base_path, id_fn, name_fn)
    else
      render_markdown_step(conn, mod, status, base_path, id_fn, name_fn)
    end
  end

  defp render_prompt(conn, mod, scope) do
    {:ok, prompt_text} = mod.command(scope, %{})
    conn |> put_resp_content_type("text/plain") |> send_resp(200, prompt_text)
  end

  defp not_found(conn, step_id) do
    conn |> put_resp_content_type("text/plain") |> send_resp(404, "Step not found: #{step_id}")
  end

  # --- Markdown ---

  defp render_markdown_checklist(conn, evaluated, base_path, title, id_fn, name_fn) do
    {done_count, total} = count_progress(evaluated)

    lines =
      Enum.map(evaluated, fn {mod, status} ->
        case status do
          :done -> "- [x] #{name_fn.(mod)}"
          {:not_done, _} -> "- [ ] [#{name_fn.(mod)}](#{base_path}/#{id_fn.(mod)})"
        end
      end)

    body = "# #{title} (#{done_count}/#{total})\n\n#{Enum.join(lines, "\n")}\n"
    conn |> put_resp_content_type("text/plain") |> send_resp(200, body)
  end

  defp render_markdown_step(conn, mod, status, base_path, id_fn, name_fn) do
    status_line =
      case status do
        :done -> "Status: done"
        {:not_done, detail} -> "Status: not done — #{detail}"
      end

    prompt_link =
      case status do
        {:not_done, _} -> "\n\nPrompt: [#{base_path}/#{id_fn.(mod)}/prompt](#{base_path}/#{id_fn.(mod)}/prompt)"
        _ -> ""
      end

    body = "# #{name_fn.(mod)}\n\n#{status_line}#{prompt_link}\n"
    conn |> put_resp_content_type("text/plain") |> send_resp(200, body)
  end

  # --- HTML ---

  defp render_html_checklist(conn, evaluated, working_dir, base_path, title, id_fn, name_fn) do
    {done_count, total} = count_progress(evaluated)
    dir_param = URI.encode_www_form(working_dir)

    rows =
      Enum.map_join(evaluated, "\n", fn {mod, status} ->
        {icon, css, link} =
          case status do
            :done ->
              {"&#10003;", "done", name_fn.(mod)}
            {:not_done, detail} ->
              {"&#9744;", "actionable",
               "<a href=\"#{base_path}/#{id_fn.(mod)}?dir=#{dir_param}\">#{name_fn.(mod)}</a>" <>
                 " <span class=\"detail\">#{esc(detail)}</span>"}
          end

        "<tr class=\"#{css}\"><td class=\"icon\">#{icon}</td><td>#{link}</td></tr>"
      end)

    pct = if total > 0, do: round(done_count / total * 100), else: 0

    html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>#{title} (#{done_count}/#{total})</title>
      <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#0f172a;color:#e2e8f0;padding:24px}
        h1{font-size:20px;margin-bottom:8px}
        .progress{background:#1e293b;border-radius:8px;height:8px;margin-bottom:24px;overflow:hidden}
        .progress-bar{background:#4ade80;height:100%}
        .subtitle{color:#94a3b8;font-size:14px;margin-bottom:16px}
        table{width:100%;max-width:700px;border-collapse:collapse}
        tr{border-bottom:1px solid #1e293b}
        td{padding:10px 8px;vertical-align:top}
        .icon{width:24px;font-size:16px;text-align:center}
        .done .icon{color:#4ade80}.actionable .icon{color:#fbbf24}
        a{color:#60a5fa;text-decoration:none}a:hover{text-decoration:underline}
        .detail{color:#94a3b8;font-size:13px;display:block;margin-top:2px}
      </style>
    </head>
    <body>
      <h1>#{title}</h1>
      <div class="subtitle">#{done_count} of #{total} steps complete</div>
      <div class="progress"><div class="progress-bar" style="width:#{pct}%"></div></div>
      <table>#{rows}</table>
    </body>
    </html>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  defp render_html_step(conn, mod, status, working_dir, scope, base_path, _id_fn, name_fn) do
    dir_param = URI.encode_www_form(working_dir)
    name = name_fn.(mod)

    status_html =
      case status do
        :done -> "<span style=\"color:#4ade80\">Done</span>"
        {:not_done, detail} -> "<span style=\"color:#fbbf24\">Not done</span> — #{esc(detail)}"
      end

    prompt_html =
      case status do
        {:not_done, _} ->
          {:ok, prompt_text} = mod.command(scope, %{})
          "<h2>Instructions</h2><pre>#{esc(prompt_text)}</pre>"
        _ -> ""
      end

    html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8"><title>#{esc(name)}</title>
      <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#0f172a;color:#e2e8f0;padding:24px;max-width:700px}
        h1{font-size:20px;margin-bottom:8px}h2{font-size:16px;margin:24px 0 8px;color:#94a3b8}
        .status{margin-bottom:24px}a{color:#60a5fa;text-decoration:none}
        pre{background:#1e293b;padding:16px;border-radius:8px;overflow-x:auto;white-space:pre-wrap;font-size:13px;line-height:1.5}
      </style>
    </head>
    <body>
      <a href="#{base_path}?dir=#{dir_param}">&larr; Back</a>
      <h1>#{esc(name)}</h1>
      <div class="status">#{status_html}</div>
      #{prompt_html}
    </body>
    </html>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  # --- Helpers ---

  defp count_progress(evaluated) do
    done = Enum.count(evaluated, fn {_, s} -> s == :done end)
    {done, length(evaluated)}
  end

  defp esc(str) do
    str |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;") |> String.replace("\"", "&quot;")
  end
end
