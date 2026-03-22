defmodule CodeMySpecLocalWeb.RequirementsGraphController do
  @moduledoc """
  LLM API for requirements graph.

  Returns raw Mermaid flowchart source as text/plain.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Requirements.GraphProjector

  def show(conn, _params) do
    scope = conn.assigns.current_scope
    mermaid = GraphProjector.project_graph(scope)
    text(conn, mermaid)
  end
end
