defmodule CodeMySpecWeb.Plugs.IntakeSession do
  @moduledoc """
  Gives an anonymous visitor a token their plan can be found by.

  A LiveView cannot write the session, so the token has to be minted on the
  way in. It is reused once present, which is what makes leaving and coming
  back in the same browser land on the plan already in progress.

  Must run after `Plug.Session`.
  """

  import Plug.Conn

  alias CodeMySpec.Intake

  @session_key "intake_token"

  def session_key, do: @session_key

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, @session_key) do
      nil -> put_session(conn, @session_key, Intake.new_session_token())
      _token -> conn
    end
  end
end
