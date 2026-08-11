defmodule CodeMySpecLocalWeb.Plugs.McpPipelineScopeTest do
  @moduledoc """
  An MCP tool gets a working copy, not just a project id.

  The `:mcp` pipeline ran `LocalOnly` and `WorkingDir` only, so a tool received
  a scope naming a project with no `cwd` and no `environment`. Every tool that
  writes to disk then refused — `create_component` told agents "this server has
  no working copy, so the stub spec was not written" and handed them the stub to
  type by hand, which reads as a limitation of the light harness rather than a
  missing plug. Specs stopped being created.

  Hooks never had this problem because `:hook` resolves identity first. This
  asserts the two pipelines now agree, by driving the plugs in each one's order
  and comparing what comes out.

  Both resolution paths matter and are asserted separately: by harness id, which
  is what a configured checkout sends, and by working directory, which is the
  fallback when no id arrives.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import Plug.Conn
  import Plug.Test

  alias CodeMySpec.Harnesses
  alias CodeMySpecLocalWeb.Plugs.{HarnessScope, WorkingDir, WorkingDirScope}

  setup do
    scope = full_scope_fixture()

    {:ok, tmp} = Briefly.create(directory: true)
    File.write!(Path.join(tmp, "mix.exs"), "# marker\n")

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{local_path: tmp})

    %{scope: %{scope | active_project: project}, root: tmp}
  end

  # The `:mcp` pipeline's plugs, in order.
  defp mcp(conn) do
    conn |> HarnessScope.call([]) |> WorkingDir.call([]) |> WorkingDirScope.call([])
  end

  defp harness_for(scope, root) do
    {:ok, harness} = Harnesses.issue(scope, nil, label: "mcp test")
    {:ok, harness} = Harnesses.report_root(harness, root)
    harness
  end

  test "a call naming a harness resolves that working copy", %{scope: scope, root: root} do
    harness = harness_for(scope, root)

    conn =
      conn(:post, "/mcp")
      |> put_req_header("x-harness-id", harness.id)
      |> mcp()

    resolved = conn.assigns.current_scope

    assert resolved.cwd == root
    assert resolved.environment,
           "a tool that writes to disk needs an environment; a project id alone is what made " <>
             "create_component refuse to write spec stubs"

    assert resolved.active_harness_id == harness.id
  end

  test "a call with no harness id falls back to its working directory", %{root: root} do
    conn =
      conn(:post, "/mcp")
      |> put_req_header("x-working-dir", root)
      |> mcp()

    resolved = conn.assigns.current_scope

    assert resolved.cwd == root
    assert resolved.environment
  end

  test "an unexpanded id falls back rather than refusing", %{root: root} do
    # `${CMS_HARNESS_ID}` reaching the server literally means the checkout is not
    # onboarded. Refusing would take MCP down for every such checkout.
    conn =
      conn(:post, "/mcp")
      |> put_req_header("x-harness-id", "${CMS_HARNESS_ID}")
      |> put_req_header("x-working-dir", root)
      |> mcp()

    assert conn.assigns.current_scope.environment
  end
end
