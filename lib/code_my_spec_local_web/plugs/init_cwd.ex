defmodule CodeMySpecLocalWeb.Plugs.InitCwd do
  @moduledoc """
  The one route that takes a directory off the wire, and the last one.

  `/api/skills/init` runs before anything has been onboarded: there is no
  harness id to route on, because issuing one is downstream of what init does.
  So it is told which directory it is about, explicitly, and refuses without.

  ## Why this is not the chain it replaced

  `Plugs.WorkingDir` accepted the same header and then *interpreted* it: it
  expanded the path, walked up to the nearest `mix.exs`, and called whatever it
  landed on the project root. That walk is the whole defect. It made one session
  resolve differently depending on which subdirectory it fired from, resolved a
  checkout nested under another to the outer one, and could not distinguish two
  checkouts at the same path on two machines. A wrong answer did not fail — it
  succeeded against the wrong disk.

  This takes the path as given. `Path.expand/1` only to make it absolute, and
  then nothing. If the caller names a subdirectory, init is about that
  subdirectory, which is a boring answer the caller can see is wrong.

  It also drops the `?dir=` query parameter the old plug accepted, which existed
  to make these routes clickable in a browser and became a second way for a
  filesystem path to arrive from outside.

  ## It should not need a directory at all

  Init's remaining job is validating the machine — Elixir, Erlang, Phoenix — and
  none of that is per-checkout. When it becomes that, this plug goes with the
  header, and `/api/skills/init` takes nothing.
  """

  import Plug.Conn

  alias CodeMySpec.Users.Scope

  @behaviour Plug

  @header "x-working-dir"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn |> get_req_header(@header) |> List.first() do
      dir when is_binary(dir) and dir != "" -> resolve(conn, Path.expand(dir))
      _ -> error(conn, 400, "#{conn.request_path} requires an X-Working-Dir header.")
    end
  end

  defp resolve(conn, dir) do
    with :ok <- exists(dir),
         {:ok, scope} <- Scope.for_local_cwd(dir) do
      conn
      |> assign(:working_dir, dir)
      |> assign(:current_scope, scope)
    else
      {:error, message} when is_binary(message) ->
        error(conn, 400, message)

      {:error, reason} ->
        error(conn, 400, "Could not build a scope for #{dir}: #{inspect(reason)}")
    end
  end

  defp exists(dir) do
    cond do
      not File.exists?(dir) -> {:error, "Path does not exist: #{dir}"}
      not File.dir?(dir) -> {:error, "Path is not a directory: #{dir}"}
      true -> :ok
    end
  end

  defp error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end
