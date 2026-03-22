defmodule CodeMySpec.LocalServer.Controllers.RequirementsGraphController do
  @moduledoc """
  Serves the project's requirements graph — content-negotiated.

  Browser (`?dir=`): HTML page with interactive Mermaid diagram
  LLM (`X-Working-Dir` header): raw Mermaid source as text/plain
  """

  import Plug.Conn

  alias CodeMySpec.Requirements.GraphProjector
  alias CodeMySpec.Requirements.RequirementsRepository
  alias CodeMySpec.Users.Scope

  @html_template """
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Requirements Graph — <%= project_name %></title>
    <style>
      * { margin: 0; padding: 0; box-sizing: border-box; }
      body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        background: #0f172a;
        color: #e2e8f0;
      }
      header {
        padding: 16px 24px;
        background: #1e293b;
        border-bottom: 1px solid #334155;
        display: flex;
        justify-content: space-between;
        align-items: center;
      }
      header h1 { font-size: 18px; font-weight: 600; }
      .stats {
        display: flex;
        gap: 16px;
        font-size: 13px;
      }
      .stat { display: flex; align-items: center; gap: 4px; }
      .dot {
        width: 10px;
        height: 10px;
        border-radius: 50%;
        display: inline-block;
      }
      .dot.satisfied { background: #60a5fa; }
      .dot.actionable { background: #4ade80; }
      .dot.blocked { background: #fbbf24; }
      #graph-container {
        width: 100%;
        height: calc(100vh - 60px);
        overflow: auto;
        display: flex;
        justify-content: center;
        padding: 24px;
      }
      .mermaid { min-width: 100%; }
      .mermaid svg { max-width: none !important; }
    </style>
  </head>
  <body>
    <header>
      <h1>Requirements Graph — <%= project_name %></h1>
      <div class="stats">
        <div class="stat"><span class="dot satisfied"></span> Satisfied: <%= counts.satisfied %></div>
        <div class="stat"><span class="dot actionable"></span> Actionable: <%= counts.actionable %></div>
        <div class="stat"><span class="dot blocked"></span> Blocked: <%= counts.blocked %></div>
        <div class="stat">Total: <%= counts.total %></div>
      </div>
    </header>
    <div id="graph-container">
      <pre class="mermaid">
  <%= mermaid %>
      </pre>
    </div>
    <script type="module">
      import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
      mermaid.initialize({
        startOnLoad: true,
        theme: 'dark',
        flowchart: {
          useMaxWidth: false,
          htmlLabels: true,
          curve: 'basis'
        },
        themeVariables: {
          darkMode: true,
          background: '#0f172a',
          primaryColor: '#1e293b',
          primaryTextColor: '#e2e8f0',
          primaryBorderColor: '#475569',
          lineColor: '#94a3b8',
          secondaryColor: '#1e293b',
          tertiaryColor: '#1e293b'
        }
      });
    </script>
  </body>
  </html>
  """

  def auto(conn) do
    if conn.assigns[:working_dir_source] == :query_param do
      show(conn)
    else
      mermaid_source(conn)
    end
  end

  def show(conn) do
    scope = conn.assigns[:current_scope]
    project = scope.active_project

    mermaid = GraphProjector.project_graph(scope)
    counts = count_statuses(scope)
    project_name = project.name || project.module_name || "Project"

    html = EEx.eval_string(@html_template,
      mermaid: mermaid,
      counts: counts,
      project_name: project_name
    )

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  def mermaid_source(conn) do
    scope = conn.assigns[:current_scope]
    mermaid = GraphProjector.project_graph(scope)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, mermaid)
  end

  defp count_statuses(%Scope{} = scope) do
    %{nodes: requirements} = RequirementsRepository.project_graph(scope)

    satisfaction_map =
      Map.new(requirements, fn r ->
        key = {entity_type(r), entity_id(r), r.name}
        {key, r.satisfied}
      end)

    counts =
      Enum.reduce(requirements, %{satisfied: 0, actionable: 0, blocked: 0}, fn req, acc ->
        cond do
          req.satisfied ->
            Map.update!(acc, :satisfied, &(&1 + 1))

          all_deps_met?(req, satisfaction_map) ->
            Map.update!(acc, :actionable, &(&1 + 1))

          true ->
            Map.update!(acc, :blocked, &(&1 + 1))
        end
      end)

    Map.put(counts, :total, length(requirements))
  end

  defp all_deps_met?(req, satisfaction_map) do
    (req.depends_on || [])
    |> Enum.all?(fn edge ->
      key = {edge["entity_type"], edge["entity_id"], edge["requirement_name"]}
      Map.get(satisfaction_map, key, true)
    end)
  end

  defp entity_type(req) when not is_nil(req.component_id), do: "component"
  defp entity_type(req) when not is_nil(req.story_id), do: "story"
  defp entity_type(req) when not is_nil(req.project_id), do: "project"

  defp entity_id(req) when not is_nil(req.component_id), do: req.component_id
  defp entity_id(req) when not is_nil(req.story_id), do: req.story_id
  defp entity_id(req) when not is_nil(req.project_id), do: req.project_id
end
