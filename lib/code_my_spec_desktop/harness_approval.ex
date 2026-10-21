defmodule CodeMySpecDesktop.HarnessApproval do
  @moduledoc """
  Approves the desktop harness's device grant for the desktop user.

  The harness and the server share one BEAM and one database, so there is no
  second person to type a code. The grant and its token are the ordinary ones,
  so refresh and revocation work as for any harness.
  """

  alias CodeMySpec.Oauth
  alias CodeMySpec.UserPreferences.DesktopUser
  alias CodeMySpec.Users

  @spec approve(String.t()) :: {:ok, term()} | {:error, term()}
  def approve(user_code) do
    with %{} = grant <- Oauth.get_device_grant_by_user_code(user_code) || {:error, :no_grant},
         %{} = user <- Users.get_user_by_email(DesktopUser.email()) || {:error, :no_desktop_user} do
      Oauth.decide_device_grant(grant, user, :approve)
    end
  end
end
