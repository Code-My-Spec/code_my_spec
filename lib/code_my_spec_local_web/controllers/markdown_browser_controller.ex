defmodule CodeMySpecLocalWeb.MarkdownBrowserController do
  @moduledoc """
  LLM API for browsing markdown file directories.

  Derives the library from the request path (e.g. `/knowledge` → `:knowledge`,
  `/project-knowledge` → `:project_knowledge`). Delegates to
  `MarkdownBrowserLive.resolve/3` for path resolution and content.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpecLocalWeb.MarkdownBrowserLive

  def show(conn, %{"project_name" => project_name, "path" => path_segments}) do
    library = library_from_path(conn)

    case MarkdownBrowserLive.resolve(library, path_segments, project_name) do
      {:ok, content} -> text(conn, content)
      {:error, :not_found} -> conn |> put_status(404) |> text("Not found")
      {:error, :invalid_path} -> conn |> put_status(400) |> text("Invalid path")
      {:error, msg} -> conn |> put_status(400) |> text("#{msg}")
    end
  end

  def index(conn, %{"project_name" => project_name}) do
    library = library_from_path(conn)

    case MarkdownBrowserLive.resolve(library, [], project_name) do
      {:ok, content} -> text(conn, content)
      {:error, msg} -> conn |> put_status(400) |> text("#{msg}")
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
