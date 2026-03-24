defmodule CodeMySpec.AgentTasks.Init.Auth do
  @moduledoc """
  Init step: authenticate with CodeMySpec.
  """

  def evaluate(_scope, _session, _opts \\ []) do
    if auth_ok?() do
      {:ok, :valid}
    else
      {:ok, :invalid, "Not authenticated with CodeMySpec"}
    end
  end

  def command(_scope, _session, _opts \\ []) do
    {:ok, """
    # Authenticate with CodeMySpec

    Start the OAuth flow, then have the user open the URL in their browser:

    ```bash
    curl -s -X POST http://localhost:4002/api/bootstrap/auth/start
    ```

    The response contains an `auth_url`. Tell the user to open it. Then verify:

    ```bash
    curl -s http://localhost:4002/api/bootstrap/auth/status
    ```

    Once `authenticated` is `true`, this step is complete.
    """}
  end

  defp auth_ok? do
    try do
      CodeMySpec.Auth.OAuthClient.authenticated?()
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end
end
