defmodule CodeMySpecLocalWeb.Plugs.WorkingDir do
  @moduledoc """
  Extracts working directory from X-Working-Dir header or ?dir= query param.

  Sets:
  - `conn.assigns.working_dir` — resolved project root
  - `conn.assigns.format` — `:markdown` (header) or `:html` (query param)
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "x-working-dir") do
      [working_dir | _] ->
        resolve_and_assign(conn, working_dir, :markdown)

      [] ->
        conn = fetch_query_params(conn)

        case Map.get(conn.query_params, "dir") do
          nil ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{error: "X-Working-Dir header or ?dir= param required"}))
            |> halt()

          dir ->
            resolve_and_assign(conn, dir, :html)
        end
    end
  end

  defp resolve_and_assign(conn, path, format) do
    expanded = Path.expand(path)

    cond do
      not File.exists?(expanded) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Path does not exist: #{expanded}"}))
        |> halt()

      not File.dir?(expanded) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Path is not a directory: #{expanded}"}))
        |> halt()

      true ->
        project_root = find_project_root(expanded, expanded)

        conn
        |> assign(:working_dir, project_root)
        |> assign(:format, format)
    end
  end

  defp find_project_root(dir, original) do
    cond do
      File.exists?(Path.join(dir, "mix.exs")) -> dir
      dir == "/" or dir == Path.dirname(dir) -> original
      true -> find_project_root(Path.dirname(dir), original)
    end
  end
end
