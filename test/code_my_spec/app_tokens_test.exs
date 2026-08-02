defmodule CodeMySpec.AppTokensTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AppTokens

  setup do
    scope = full_scope_fixture()
    project = scope.active_project
    {:ok, project} = AppTokens.put_refresh_secret(project, "the-refresh-secret")

    %{scope: scope, project: project}
  end

  describe "exchange/1" do
    test "a refresh secret buys a token and its lifetime", %{} do
      assert {:ok, token, expires_in} = AppTokens.exchange("the-refresh-secret")

      assert is_binary(token) and token != ""
      assert is_integer(expires_in) and expires_in > 0
    end

    test "an unknown secret buys nothing" do
      assert {:error, :invalid} = AppTokens.exchange("not-the-secret")
    end

    # Blank and nil are the shapes a misconfigured deployment sends — an app
    # whose env var never got set. They must not exchange for anything.
    test "an empty or missing secret buys nothing" do
      assert {:error, :invalid} = AppTokens.exchange("")
      assert {:error, :invalid} = AppTokens.exchange(nil)
    end

    # Criterion 8020: renewal produces a genuinely different token, so a client
    # that renewed is not still presenting the one that is about to age out.
    # Criterion 8020, and the reason tokens carry a nonce. `Phoenix.Token.sign`
    # stamps whole seconds, so without one two exchanges in the same second are
    # byte-identical and a client that renewed still holds the token about to
    # lapse — having been told it was new. No sleep here on purpose: the same
    # second is exactly the case that broke.
    test "renewing produces a different token, even within the same second", %{} do
      {:ok, first, _} = AppTokens.exchange("the-refresh-secret")
      {:ok, second, _} = AppTokens.exchange("the-refresh-secret")

      refute first == second
      assert {:ok, _} = AppTokens.verify(first)
      assert {:ok, _} = AppTokens.verify(second)
    end
  end

  describe "verify/1" do
    test "a fresh token names its project", %{project: project} do
      {:ok, token, _} = AppTokens.exchange("the-refresh-secret")

      assert {:ok, verified} = AppTokens.verify(token)
      assert verified.id == project.id
    end

    # Criterion 8046 / 8045: the durable secret opens the exchange and nothing
    # else. If this passed, a copy of the deployed environment would be a copy
    # of the app's access, and the exchange would be decoration.
    test "the refresh secret itself is not a token" do
      assert {:error, :invalid} = AppTokens.verify("the-refresh-secret")
    end

    test "a token we never issued is invalid" do
      assert {:error, :invalid} = AppTokens.verify("not-a-token")
      assert {:error, :invalid} = AppTokens.verify("")
      assert {:error, :invalid} = AppTokens.verify(nil)
    end

    # Criterion 8023: "renew and retry" and "your credential is wrong, stop
    # retrying" are different instructions, so they cannot be the same refusal.
    test "an aged-out token is expired, not invalid", %{} do
      {:ok, token, _} = AppTokens.exchange("the-refresh-secret")

      # Signed a lifetime ago rather than sleeping through one.
      old =
        Phoenix.Token.sign(
          Application.get_env(:code_my_spec, CodeMySpecWeb.Endpoint)[:secret_key_base],
          "app access token",
          AppTokens.verify(token) |> elem(1) |> Map.get(:id),
          signed_at: System.system_time(:second) - AppTokens.max_age() - 60
        )

      assert {:error, :expired} = AppTokens.verify(old)
      refute AppTokens.verify(old) == AppTokens.verify("not-a-token")
    end

    # A token for a project that has since been deleted is not "expired" —
    # waiting will not help, so it must not tell a client to renew.
    test "a token whose project is gone is invalid, not expired", %{project: project} do
      {:ok, token, _} = AppTokens.exchange("the-refresh-secret")
      Repo.delete!(project)

      assert {:error, :invalid} = AppTokens.verify(token)
    end
  end

  describe "the secret is stored as a digest" do
    # The plaintext must not be queryable, or it ends up in query logs.
    test "only a digest is persisted", %{project: project} do
      reloaded = Repo.get!(CodeMySpec.Projects.Project, project.id)

      assert reloaded.cms_refresh_secret_hash == AppTokens.hash("the-refresh-secret")
      refute reloaded.cms_refresh_secret_hash == "the-refresh-secret"
    end
  end
end
