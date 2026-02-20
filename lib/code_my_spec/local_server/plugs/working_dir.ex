defmodule CodeMySpec.LocalServer.Plugs.WorkingDir do
  @moduledoc """
  Extracts and validates the X-Working-Dir header for local MCP connections.

  The working directory tells the MCP server which project Claude Code is
  connected from. This plug traverses up from the given directory to find
  the project root (containing `mix.exs`), enabling commands to work from
  any subdirectory within a project. Falls back to the provided directory
  if no `mix.exs` is found (e.g., pre-init bootstrap).
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
        case resolve_project_root(working_dir) do
          {:ok, project_root} ->
            Logger.debug(
              "[LocalServer] Working directory: #{working_dir} -> project root: #{project_root}"
            )

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
        find_project_root(expanded, expanded)
    end
  end

  # Traverses up the directory tree looking for mix.exs.
  # Falls back to the original directory if not found (pre-init bootstrap).
  defp find_project_root(dir, original_dir) do
    mix_exs_path = Path.join(dir, "mix.exs")

    cond do
      File.exists?(mix_exs_path) ->
        {:ok, dir}

      dir == "/" or dir == Path.dirname(dir) ->
        # No mix.exs found — fall back to the provided directory
        {:ok, original_dir}

      true ->
        find_project_root(Path.dirname(dir), original_dir)
    end
  end
end
