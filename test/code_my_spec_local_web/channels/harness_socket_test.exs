defmodule CodeMySpecLocalWeb.HarnessSocketTest do
  @moduledoc """
  The harness data-plane socket is gated by the machine-local
  `CodeMySpec.AgentHarness.Secret` — the offsite harness presents it as the
  `token` param, never the user's server OAuth token. A missing/wrong secret is
  rejected; the correct secret resolves the local project scope from
  `external_id = "pi:<local_path>"`.
  """

  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentHarness.Secret

  @endpoint CodeMySpecLocalWeb.Endpoint

  # Matches config/test.exs :harness_secret.
  @secret "test-harness-secret"

  describe "Secret.valid?/1" do
    test "true only for the machine secret" do
      assert Secret.valid?(@secret)
      refute Secret.valid?("nope")
      refute Secret.valid?("")
      refute Secret.valid?(nil)
    end
  end

  describe "connect/3" do
    test "rejects a missing or wrong secret" do
      assert :error = connect(CodeMySpecLocalWeb.HarnessSocket, %{"external_id" => "pi:/tmp/x"})

      assert :error =
               connect(CodeMySpecLocalWeb.HarnessSocket, %{
                 "token" => "wrong",
                 "external_id" => "pi:/tmp/x"
               })
    end

    test "accepts the machine secret and resolves the local project scope" do
      project = local_project()

      assert {:ok, socket} =
               connect(CodeMySpecLocalWeb.HarnessSocket, %{
                 "token" => @secret,
                 "external_id" => "pi:#{project.local_path}"
               })

      assert socket.assigns.scope.active_project_id == project.id
      assert socket.assigns.account_id == project.account_id
      assert socket.assigns.external_id == "pi:#{project.local_path}"
    end

    test "rejects the correct secret when the working dir has no linked project" do
      assert :error =
               connect(CodeMySpecLocalWeb.HarnessSocket, %{
                 "token" => @secret,
                 "external_id" => "pi:/tmp/not-a-linked-project"
               })
    end
  end

  defp local_project do
    scope = full_scope_fixture()
    {:ok, project} = CodeMySpec.Projects.update_project(scope, scope.active_project, %{local_path: "/tmp/harness-socket-test"})
    project
  end
end
