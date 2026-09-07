defmodule CodeMySpec.AgentTasks.Init.Auth do
  @moduledoc """
  Init step: authenticate with CodeMySpec.
  """

  alias CodeMySpec.Auth.OAuthClient

  def evaluate(_scope, _task) do
    if auth_ok?() do
      {:ok, :valid}
    else
      {:ok, :invalid, "Not authenticated with CodeMySpec"}
    end
  end

  def command(_scope, _task) do
    {:ok, """
    # Authenticate with CodeMySpec

    Ask the user to authenticate with CodeMySpec. They need to:

    1. Open the CodeMySpec web app and sign in
    2. Run the auth flow from the CLI or visit the auth URL

    This step requires user interaction — you cannot complete it automatically.

    Once authenticated, call `get_next_requirement` to continue.
    """}
  end

  defp auth_ok? do
    OAuthClient.authenticated?()
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
