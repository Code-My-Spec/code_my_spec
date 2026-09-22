defmodule CodeMySpec.Workspaces.InstancePreviewProvisioningTest do
  @moduledoc """
  A cloud instance's main copy is handed real preview credentials at boot.

  `mix harness.onboard` does this for a checkout onboarded by hand: it asks
  `ClientUtils.Harness.Preview.ensure/4`, which POSTs to this same server and
  lands on `HarnessLookupController.preview/2`, which calls
  `PreviewTunnel.ensure/1`. Nothing plays that task's part for an instance the
  server boots itself — `Runner.Local`'s identity is written directly by
  `Workspaces`, not minted by any onboarding task — so before this fix a
  bare-metal instance's `.cms_harness.json` never carried a `preview_*` key at
  all, and `ClientUtils.CloudflareTunnel` stayed `enabled: false` forever.
  Measured live, 2026-09-21: an agent told to "deploy" a project had no tool
  that could ever make this true.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Workspaces
  alias CodeMySpecTest.FakeWorkspaceRunner
  alias Req.Test

  @tunnel_id "d3f1c0de-0000-4000-8000-000000000099"

  setup do
    CodeMySpecSpex.Fixtures.install_workspace_runner(healthy?: true, serving: :serving)

    user = user_fixture()
    account = account_fixture(%{name: "Preview boot #{System.unique_integer([:positive])}"})

    scope = %Scope{
      user: user,
      user_id: user.id,
      active_account: account,
      active_account_id: account.id
    }

    project = CodeMySpec.ProjectsFixtures.project_fixture(scope, %{name: "previewboot"})
    scope = %Scope{scope | active_project: project, active_project_id: project.id}

    %{scope: scope}
  end

  defp stub_cloudflare do
    Test.stub(CodeMySpec.Workspaces.PreviewTunnel, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = Jason.decode!(body)
      cloudflare_json(conn, String.contains?(conn.request_path, "cfd_tunnel"), params)
    end)
  end

  defp cloudflare_json(conn, true, _params),
    do: Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => @tunnel_id}})

  defp cloudflare_json(conn, false, _params),
    do: Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-1"}})

  defp booted_env do
    [{_name, _app, _port, env} | _] = FakeWorkspaceRunner.calls()
    Map.new(env)
  end

  test "the instance is handed a real tunnel credential", %{scope: scope} do
    stub_cloudflare()

    {:ok, _workspace} = Workspaces.boot(scope)

    env = booted_env()

    assert env["CMS_PREVIEW_URL"], "no preview means no tool an agent has can ever make one"
    assert env["CMS_PREVIEW_TUNNEL_ID"] == @tunnel_id
    assert is_binary(env["CMS_PREVIEW_TUNNEL_SECRET"]) and env["CMS_PREVIEW_TUNNEL_SECRET"] != ""
    assert env["CMS_PREVIEW_ACCOUNT_TAG"] == "test-account"
    assert is_binary(env["CMS_PREVIEW_EMBEDDER"])
  end

  # Best-effort, like the deploy key and server url: a boot Cloudflare refuses
  # still produces a running application. A crash here would take the whole
  # instance down over a frame the visitor was never guaranteed anyway.
  test "a refused tunnel still lets the instance boot, with no preview keys", %{scope: scope} do
    Test.stub(CodeMySpec.Workspaces.PreviewTunnel, fn conn ->
      Test.json(conn, %{"success" => false, "errors" => [%{"code" => 9999}]})
    end)

    {:ok, _workspace} = Workspaces.boot(scope)

    env = booted_env()

    refute Map.has_key?(env, "CMS_PREVIEW_URL")
    refute Map.has_key?(env, "CMS_PREVIEW_TUNNEL_ID")
    refute Map.has_key?(env, "CMS_PREVIEW_TUNNEL_SECRET")
  end
end
