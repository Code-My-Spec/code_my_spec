defmodule CodeMySpecLocalWeb.MarkdownBrowserController do
  @moduledoc """
  LLM API for browsing markdown file directories.

  Derives the library from the request path (e.g. `/knowledge` → `:knowledge`,
  `/project-knowledge` → `:project_knowledge`). Delegates to
  `CodeMySpec.Knowledge.resolve/3` for path resolution and content.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Knowledge
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  def show(conn, %{"project_name" => project_name, "path" => path_segments}) do
    library = library_from_path(conn)

    with {:ok, scope} <- resolve_scope(project_name),
         {:ok, content} <- Knowledge.resolve(scope, library, path_segments) do
      text(conn, content)
    else
      {:error, :not_found} -> conn |> put_status(404) |> text("Not found")
      {:error, :invalid_path} -> conn |> put_status(400) |> text("Invalid path")
      {:error, msg} -> conn |> put_status(400) |> text("#{msg}")
    end
  end

  def index(conn, %{"project_name" => project_name}) do
    library = library_from_path(conn)

    with {:ok, scope} <- resolve_scope(project_name),
         {:ok, content} <- Knowledge.resolve(scope, library, []) do
      text(conn, content)
    else
      {:error, msg} -> conn |> put_status(400) |> text("#{msg}")
    end
  end

  defp resolve_scope(project_name) do
    with {:ok, project} <- Projects.get_project_by_name(project_name) do
      Scope.for_local_project(project)
    end
  end

  # Derive library atom from the path segment after project_name.
  # e.g. /api/projects/foo/knowledge → :knowledge
  #      /api/projects/foo/project-knowledge → :project_knowledge
  defp library_from_path(conn) do
    conn.path_info
    |> Enum.drop_while(&(&1 != conn.params["project_name"]))
    |> Enum.at(1, "")
    |> String.replace("-", "_")
    |> String.to_existing_atom()
  end
end
