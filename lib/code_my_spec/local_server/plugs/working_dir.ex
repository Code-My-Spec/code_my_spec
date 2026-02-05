defmodule CodeMySpec.LocalServer.Plugs.WorkingDir do
  @moduledoc """
  Extracts and validates the X-Working-Dir header for local MCP connections.

  The working directory tells the MCP server which project Claude Code is
  connected from. This plug traverses up from the given directory to find
  the project root (containing `.code_my_spec/config.yml`), enabling
  commands to work from any subdirectory within a project.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @config_dir ".code_my_spec"
  @config_file "config.yml"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "x-working-dir") do
      [working_dir | _] ->
        case resolve_project_root(working_dir) do
          {:ok, project_root} ->
            Logger.debug("[LocalServer] Working directory: #{working_dir} -> project root: #{project_root}")
            assign(conn, :working_dir, project_root)

          {:error, reason} ->
            Logger.warning("[LocalServer] Invalid working directory: #{reason}")

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{error: "Invalid working directory: #{reason}"}))
            |> halt()
        end

      [] ->
        Logger.warning("[LocalServer] Missing X-Working-Dir header")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "X-Working-Dir header is required"}))
        |> halt()
    end
  end

  # Validates the path exists, then traverses up to find the project root
  defp resolve_project_root(path) do
    expanded = Path.expand(path)

    cond do
      not File.exists?(expanded) ->
        {:error, "Path does not exist"}

      not File.dir?(expanded) ->
        {:error, "Path is not a directory"}

      true ->
        find_project_root(expanded)
    end
  end

  # Traverses up the directory tree to find the project root
  defp find_project_root(dir) do
    config_path = Path.join([dir, @config_dir, @config_file])

    cond do
      File.exists?(config_path) ->
        {:ok, dir}

      dir == "/" or dir == Path.dirname(dir) ->
        {:error, "No .code_my_spec/config.yml found in directory tree"}

      true ->
        find_project_root(Path.dirname(dir))
    end
  end
end
