defmodule CodeMySpec.Provisioning.Tools.ConnectProviderTest do
  @moduledoc """
  An agent connects a provider without ever holding its token: it gets the
  consent link, the person approves, the token lands on the server. Issue
  e2a9ed8c.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Integrations.IntegrationRepository
  alias CodeMySpec.Integrations.OAuthHandoff
  alias CodeMySpec.Provisioning.Tools.AwaitProviderConnection
  alias CodeMySpec.Provisioning.Tools.ConnectProvider

  setup do
    scope = full_scope_fixture()
    %{scope: scope, context: %{scope: scope}}
  end

  describe "connect_provider" do
    test "hands back the provider's consent link and parks the flow under its state", %{
      context: context
    } do
      assert {:ok, text} = ConnectProvider.call(%{provider: "github"}, context)

      [url] = Regex.run(~r{https://github\.com\S+}, text)
      %{"state" => state} = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert {:ok, %{provider: :github, flow: :integration}} = OAuthHandoff.claim(state)
      assert text =~ "await_provider_connection"
    end

    test "a provider that is already connected is not asked for again", %{
      scope: scope,
      context: context
    } do
      connect(scope, :github)
      stub_github(200)

      assert {:ok, text} = ConnectProvider.call(%{provider: "github"}, context)
      assert text =~ "already connected"
      refute text =~ "https://"
    end

    test "a revoked GitHub grant gives a new consent link", %{scope: scope, context: context} do
      connect(scope, :github)
      stub_github(401)

      assert {:ok, text} = ConnectProvider.call(%{provider: "github"}, context)
      assert text =~ "https://github.com"
      assert text =~ "await_provider_connection"
    end

    test "a GitHub outage leaves connection status unknown", %{scope: scope, context: context} do
      connect(scope, :github)
      stub_github(503)

      assert {:error, text} = ConnectProvider.call(%{provider: "github"}, context)
      assert text =~ "could not check"
      refute text =~ "already connected"
      refute text =~ "https://"
    end

    test "a GitHub network error leaves connection status unknown", %{
      scope: scope,
      context: context
    } do
      connect(scope, :github)
      Req.Test.stub(ConnectProvider, &Req.Test.transport_error(&1, :nxdomain))

      assert {:error, text} = ConnectProvider.call(%{provider: "github"}, context)
      assert text =~ "could not check"
    end

    test "a provider that is not on the list is refused", %{context: context} do
      assert {:error, text} = ConnectProvider.call(%{provider: "hetzner"}, context)
      assert text =~ "unknown provider"
    end
  end

  describe "await_provider_connection" do
    test "says it is connected once the person has approved", %{scope: scope, context: context} do
      connect(scope, :github)

      assert {:ok, text} =
               AwaitProviderConnection.call(%{provider: "github", wait_seconds: 0}, context)

      assert text =~ "github is connected"
    end

    test "says the person has not approved yet, without a credential in the answer", %{
      context: context
    } do
      assert {:ok, text} =
               AwaitProviderConnection.call(%{provider: "github", wait_seconds: 0}, context)

      assert text =~ "not connected yet"
    end
  end

  describe "await_provider_connection's wait" do
    # A tool called from run_script gets ~28s; a longer wait crashed
    # restart_app the same way (issue 0b1ae6fc).
    test "above the cap is clamped to it" do
      assert AwaitProviderConnection.wait_seconds(%{wait_seconds: 120}) == 25
    end

    test "defaults to 20 and is never negative" do
      assert AwaitProviderConnection.wait_seconds(%{}) == 20
      assert AwaitProviderConnection.wait_seconds(%{wait_seconds: -5}) == 0
    end
  end

  defp stub_github(status) do
    Req.Test.stub(ConnectProvider, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/user"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(%{login: "test-user"}))
    end)
  end

  defp connect(scope, provider) do
    {:ok, _} =
      IntegrationRepository.upsert_integration(scope, provider, %{
        access_token: "test-token",
        refresh_token: "test-refresh",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        granted_scopes: ["repo"],
        provider_metadata: %{provider_user_id: "u1", email: "a@example.com", name: "A"}
      })
  end
end
