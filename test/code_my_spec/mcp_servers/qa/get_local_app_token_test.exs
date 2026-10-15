defmodule CodeMySpec.McpServers.Qa.GetLocalAppTokenTest.FakeSpriteToken do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts), do: reply(conn, get_req_header(conn, "authorization"))

  defp reply(conn, ["Bearer " <> key]) when key != "" do
    send(self_test_pid(), {:received_deploy_key, key})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"access_token" => "minted-token-abc", "expires_in" => 3600}))
  end

  defp reply(conn, _no_bearer_key) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{"error" => "invalid_token"}))
  end

  # The test process registered itself under this name before starting the
  # server, so the request handler (running in its own process) can report
  # what it actually received back to the test.
  defp self_test_pid, do: Process.whereis(:get_local_app_token_test_listener)
end

defmodule CodeMySpec.McpServers.Qa.GetLocalAppTokenTest.FakeRefusingSpriteToken do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{"error" => "invalid_token"}))
  end
end

defmodule CodeMySpec.McpServers.Qa.GetLocalAppTokenTest do
  @moduledoc """
  b3005df9: the token-minting half of letting QA call a copy's own
  /mcp/harness before promotion. Covers that the exchange actually happens
  against the url the caller named (not some fixed server), that the result
  hands back the minted token and never the deploy key used to get it, and
  that a missing key or an unreachable/refusing server is reported rather
  than raised.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.McpServers.Qa.GetLocalAppTokenTest.FakeRefusingSpriteToken
  alias CodeMySpec.McpServers.Qa.GetLocalAppTokenTest.FakeSpriteToken
  alias CodeMySpec.McpServers.Qa.Tools.GetLocalAppToken

  defp response_text(response) do
    response
    |> Response.to_protocol()
    |> Map.get("content")
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
  end

  defp start_fake(plug) do
    bandit = start_supervised!({Bandit, plug: plug, port: 0, startup_log: false})
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    "http://127.0.0.1:#{port}"
  end

  describe "no url given" do
    test "is told what it needs" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, reply, _frame} = GetLocalAppToken.execute(%{}, frame)

      assert response_text(reply) =~ "url is required"
    end
  end

  describe "a project with a deploy key, against a server that mints a token" do
    test "returns the minted token and never the deploy key used to get it" do
      Process.register(self(), :get_local_app_token_test_listener)
      scope = full_scope_fixture(%{deploy_key: "deploy-key-for-this-test"})
      frame = %Frame{assigns: %{current_scope: scope}}
      url = start_fake(FakeSpriteToken)

      {:reply, reply, _frame} = GetLocalAppToken.execute(%{url: url}, frame)

      text = response_text(reply)

      assert_receive {:received_deploy_key, "deploy-key-for-this-test"},
                     1000,
                     "the exchange never reached the url this call named"

      assert text =~ "minted-token-abc",
             "the minted token is not in the reply:\n#{text}"

      assert text =~ "call_mcp_server",
             "the reply does not say how to use the token:\n#{text}"

      assert text =~ "/mcp/harness",
             "the reply does not name the path to call it on:\n#{text}"

      refute text =~ "deploy-key-for-this-test",
             "the deploy key used to get the token must never appear in the reply:\n#{text}"
    end
  end

  describe "a server that refuses the deploy key" do
    @tag :capture_log
    test "reports the refusal rather than raising" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}
      url = start_fake(FakeRefusingSpriteToken)

      {:reply, reply, _frame} = GetLocalAppToken.execute(%{url: url}, frame)

      text = response_text(reply)

      assert text =~ "Could not get a token",
             "a refused exchange is not reported as a refusal:\n#{text}"

      refute text =~ scope.active_project.deploy_key,
             "the deploy key must never appear in the reply even on refusal:\n#{text}"
    end
  end

  describe "nothing listening at the named url" do
    @tag :capture_log
    test "reports unreachable rather than raising" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, reply, _frame} = GetLocalAppToken.execute(%{url: "http://127.0.0.1:1"}, frame)

      assert response_text(reply) =~ "Could not get a token"
    end
  end
end
