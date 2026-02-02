defmodule CodeMySpec.LocalServer.Plugs.WorkingDir do
  @moduledoc """
  Extracts and validates the X-Working-Dir header for local MCP connections.

  The working directory tells the MCP server which project Claude Code is
  connected from. This enables session isolation when multiple Claude Code
  instances connect to the same server.
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
        case validate_working_dir(working_dir) do
          {:ok, validated_dir} ->
            Logger.debug("[LocalServer] Working directory: #{validated_dir}")
            assign(conn, :working_dir, validated_dir)

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

  defp validate_working_dir(path) do
    expanded = Path.expand(path)

    cond do
      not File.exists?(expanded) ->
        {:error, "Path does not exist"}

      not File.dir?(expanded) ->
        {:error, "Path is not a directory"}

      true ->
        {:ok, expanded}
    end
  end
end
