defmodule CodeMySpecWeb.WidgetSocketTokenController do
  @moduledoc """
  Mints a browser-safe token for the widget socket.

  The socket authenticates with the project's deploy key today, and that key
  deliberately never reaches the browser — the widget runs in the target app's
  backend. This gives the backend something it *can* hand to the browser:
  short-lived, scoped to the socket, useless against the REST surfaces.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.AppTokens

  def show(conn, _params) do
    project = conn.assigns.app_token_project
    {token, expires_in} = AppTokens.issue_socket_token(project)

    json(conn, %{"socket_token" => token, "expires_in" => expires_in})
  end
end
