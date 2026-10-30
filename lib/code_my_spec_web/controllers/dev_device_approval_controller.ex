defmodule CodeMySpecWeb.DevDeviceApprovalController do
  @moduledoc """
  Approve a device grant for unattended development onboarding tests.

  This controller is reachable only through the router's compile-time
  `:dev_routes` block. It checks the test user's password and delegates the
  decision to the same OAuth context used by the browser approval page.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.{Oauth, Users}

  def create(conn, %{"email" => email, "password" => password, "user_code" => code})
      when is_binary(email) and is_binary(password) and is_binary(code) do
    with user when not is_nil(user) <- Users.get_user_by_email_and_password(email, password),
         grant when not is_nil(grant) <- Oauth.get_device_grant_by_user_code(code),
         {:ok, _grant} <- Oauth.decide_device_grant(grant, user, :approve) do
      json(conn, %{approved: true})
    else
      _ -> refuse(conn)
    end
  end

  def create(conn, _params), do: refuse(conn)

  defp refuse(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Could not approve device code"})
  end
end
