defmodule CmsHarnessTest.HarnessOAuthFixture do
  @moduledoc "Isolated persisted harness credentials for synchronous integration tests."

  alias CodeMySpec.Auth.HarnessOAuth

  def server_url, do: CmsHarness.Config.server_url()

  def isolate do
    previous = Application.fetch_env(:code_my_spec, HarnessOAuth)
    dir = CodeMySpec.TempFile.dir("harness-oauth-fixture")
    File.mkdir_p!(dir)
    Application.put_env(:code_my_spec, HarnessOAuth, state_dir: dir)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:code_my_spec, HarnessOAuth, value)
        :error -> Application.delete_env(:code_my_spec, HarnessOAuth)
      end

      File.rm_rf(dir)
    end)

    dir
  end

  def seed(dir, server, token) do
    hash =
      :crypto.hash(:sha256, String.trim_trailing(server, "/"))
      |> Base.encode16(case: :lower)

    path = Path.join(dir, "harness_oauth_#{hash}.json")

    File.write!(
      path,
      Jason.encode!(%{
        client_id: "fixture-harness-client",
        client_secret: "fixture-client-secret",
        access_token: token,
        refresh_token: "fixture-refresh",
        expires_at: System.system_time(:second) + 7200
      })
    )

    File.chmod!(path, 0o600)
    path
  end
end
