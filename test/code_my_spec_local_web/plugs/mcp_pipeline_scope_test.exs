defmodule CodeMySpecLocalWeb.Plugs.McpPipelineScopeTest do
  @moduledoc """
  An MCP tool gets a working copy, not just a project id.

  The `:mcp` pipeline ran `LocalOnly` and `WorkingDir` only, so a tool received
  a scope naming a project with no `cwd` and no `environment`. Every tool that
  writes to disk then refused — `create_component` told agents "this server has
  no working copy, so the stub spec was not written" and handed them the stub to
  type by hand, which reads as a limitation of the light harness rather than a
  missing plug. Specs stopped being created.

  Hooks never had this problem because `:hook` resolves identity first. The two
  pipelines are now the same two plugs, and this drives them in order to check
  that what comes out is a scope a tool can write through.

  The directory cases that used to be here are gone with the behaviour: there is
  no second way to name a working copy, so there is nothing to assert about one.
  What replaced them is the refusal — a request that names no harness is
  answered, not resolved.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import Plug.Conn
  import Plug.Test

  alias CodeMySpec.Harnesses
  alias CodeMySpecLocalWeb.Plugs.HarnessScope

  setup do
    scope = full_scope_fixture()

    {:ok, tmp} = Briefly.create(directory: true)
    File.write!(Path.join(tmp, "mix.exs"), "# marker\n")

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{local_path: tmp})

    %{scope: %{scope | active_project: project}, root: tmp}
  end

  # The `:mcp` pipeline's scope resolution. `LocalOnly` is omitted — it decides
  # whether the request is allowed in, not which working copy it is about.
  defp mcp(conn), do: HarnessScope.call(conn, [])

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

  test "a call naming no harness is refused, not resolved by its directory", %{root: root} do
    conn =
      conn(:post, "/mcp")
      |> put_req_header("x-working-dir", root)
      |> mcp()

    assert conn.halted
    assert conn.status == 400
    refute conn.assigns[:current_scope]

    assert Jason.decode!(conn.resp_body)["error"] =~ "X-Harness-Id"
  end

  test "an unexpanded id is refused and names the fix", %{root: root} do
    # `${CMS_HARNESS_ID}` reaching the server literally means the checkout was
    # never onboarded. It used to fall back to the directory, which is how a
    # checkout with no id at all still got a working copy — someone else's, if
    # the walk landed there.
    conn =
      conn(:post, "/mcp")
      |> put_req_header("x-harness-id", "${CMS_HARNESS_ID}")
      |> put_req_header("x-working-dir", root)
      |> mcp()

    assert conn.halted
    assert conn.status == 400
    refute conn.assigns[:current_scope]

    assert Jason.decode!(conn.resp_body)["error"] =~ "cms.harness.onboard"
  end
end
