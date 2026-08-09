defmodule CodeMySpecWeb.Plugs.CurrentPath do
  @moduledoc """
  Puts the request path on the conn so dead views know where they are.

  LiveViews get this from `CodeMySpecWeb.CurrentPathHook`. Controller-rendered
  pages had no equivalent, which is why the marketing nav could not tell you
  which section you were in — it had no way to know.

  The query string is deliberately dropped. Nothing in the nav varies by it,
  and including it would make `/blog` and `/blog?page=2` different places for
  the purpose of highlighting a link that points at both.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: Plug.Conn.assign(conn, :current_path, conn.request_path)
end
