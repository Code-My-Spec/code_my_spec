defmodule CodeMySpecWeb.IntakeResetController do
  @moduledoc """
  Wipes a test run of guided intake back to the root, for testing the funnel
  itself rather than any one plan.

  `UserAuth.log_out_user/1` looks like the same job and is not: it carries the
  intake token across on purpose, so a visitor who logs out mid-conversation
  does not lose the plan they were building. That is the right behavior for a
  real visitor and the wrong one here — the whole point of a reset is a new
  plan, so this clears the session completely rather than preserving anything
  across it.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Users

  def create(conn, _params) do
    user_token = get_session(conn, :user_token)
    user_token && Users.delete_user_session_token(user_token)
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> redirect(to: ~p"/build/procedural")
  end
end
