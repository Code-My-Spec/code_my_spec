defmodule CodeMySpecLocalWeb.Plugs.AntigravityWorkspace do
  @moduledoc """
  Bridges Antigravity hook payloads into the X-Working-Dir convention.

  Antigravity hooks deliver the workspace as `workspacePaths` (array of
  absolute paths) in the JSON body rather than a header. This plug lifts
  the first entry into the `x-working-dir` request header so the standard
  `WorkingDir` → `WorkingDirScope` chain resolves scope exactly as it does
  for Claude Code hooks. An explicit header, if present, wins.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with [] <- get_req_header(conn, "x-working-dir"),
         [path | _] when is_binary(path) <- Map.get(conn.body_params, "workspacePaths") do
      put_req_header(conn, "x-working-dir", path)
    else
      _ -> conn
    end
  end
end
