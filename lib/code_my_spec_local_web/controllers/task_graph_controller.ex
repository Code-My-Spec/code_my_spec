defmodule CodeMySpecLocalWeb.TaskGraphController do
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Tasks.TaskGraphProjector

  def show(conn, _params) do
    scope = conn.assigns.current_scope
    project = scope.active_project
    mermaid = TaskGraphProjector.project_for_project(project.id)

    case conn.assigns.format do
      :markdown ->
        text(conn, mermaid)

      :html ->
        # TODO: move to HEEx template
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, render_mermaid_html(mermaid, project))
    end
  end

  defp render_mermaid_html(mermaid, project) do
    project_name = project.name || project.module_name || "Project"

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <title>Task Graph — #{project_name}</title>
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, sans-serif; background: #0f172a; color: #e2e8f0; }
        header { padding: 16px 24px; background: #1e293b; border-bottom: 1px solid #334155; }
        header h1 { font-size: 18px; }
        #graph { padding: 24px; display: flex; justify-content: center; }
      </style>
    </head>
    <body>
      <header><h1>Task Graph — #{project_name}</h1></header>
      <div id="graph"><pre class="mermaid">#{mermaid}</pre></div>
      <script type="module">
        import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
        mermaid.initialize({ startOnLoad: true, theme: 'dark' });
      </script>
    </body>
    </html>
    """
  end
end
