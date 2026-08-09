defmodule CodeMySpecLocalWeb.Plugs.HarnessScopeTest do
  @moduledoc """
  Routing a hook by the id it names rather than the directory it fired from.

  The property under test is that the working directory stops deciding
  anything. Two checkouts of one project are two harnesses whatever their paths
  say, and a hook fired from a subdirectory resolves to the same harness as one
  fired from the root — neither of which the `mix.exs` walk this replaces could
  promise.

  Driven through the plug rather than the endpoint because the question is what
  the scope comes out as, and the controllers behind it each do their own
  different work with it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import Plug.Conn
  import Plug.Test

  alias CodeMySpec.Harnesses
  alias CodeMySpecLocalWeb.Plugs.HarnessScope

  setup do
    scope = full_scope_fixture()
    project = scope.active_project

    {:ok, tmp} = Briefly.create(directory: true)
    File.write!(Path.join(tmp, "mix.exs"), "# marker\n")

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, project, %{local_path: tmp})

    %{scope: scope, project: project, root: tmp}
  end

  defp harness(scope, root, opts \\ [])

  defp harness(scope, nil, opts) do
    {:ok, harness} = Harnesses.issue(scope, nil, label: opts[:label])
    harness
  end

  defp harness(scope, root, opts) do
    {:ok, harness} = scope |> harness(nil, opts) |> Harnesses.report_root(root)
    harness
  end

  defp call(headers) do
    Enum.reduce(headers, conn(:post, "/api/hooks/stop"), fn {k, v}, c ->
      put_req_header(c, k, v)
    end)
    |> HarnessScope.call([])
  end

  describe "an id that names a harness" do
    test "resolves the project and root without consulting the request path", %{
      scope: scope,
      root: root
    } do
      h = harness(scope, root)

      conn = call([{"x-harness-id", h.id}])

      refute conn.halted
      assert conn.assigns.current_scope.active_harness_id == h.id
      assert conn.assigns.working_dir == root
    end

    test "the harness's own root wins over the directory the hook announced", %{
      scope: scope,
      root: root
    } do
      h = harness(scope, root)

      conn = call([{"x-harness-id", h.id}, {"x-working-dir", "/somewhere/else/entirely"}])

      assert conn.assigns.working_dir == root,
             "the announced directory is where the agent happened to be; the root " <>
               "is what the working copy reported about itself"
    end

    test "two harnesses of one project resolve to different scopes", %{
      scope: scope,
      root: root
    } do
      a = harness(scope, root, label: "checkout a")
      b = harness(scope, root, label: "checkout b")

      assert a.id != b.id

      scope_a = call([{"x-harness-id", a.id}]).assigns.current_scope
      scope_b = call([{"x-harness-id", b.id}]).assigns.current_scope

      assert scope_a.active_harness_id == a.id
      assert scope_b.active_harness_id == b.id

      refute scope_a.active_harness_id == scope_b.active_harness_id,
             "same project, same path, two checkouts — this is the case no " <>
               "path-derived identity can tell apart"
    end
  end

  describe "an id that names nothing" do
    test "a stale id is refused by name rather than 404ing on a path", %{scope: scope} do
      _real = harness(scope, nil)
      gone = Ecto.UUID.generate()

      conn = call([{"x-harness-id", gone}])

      assert conn.halted
      assert conn.status == 404
      assert conn.resp_body =~ gone
      assert conn.resp_body =~ ".cms_harness.json"
    end

    test "a malformed id is a 400, not a 404" do
      conn = call([{"x-harness-id", "not-a-uuid"}])

      assert conn.status == 400,
             "the caller sent nonsense, which is a different problem from an id " <>
               "the server does not have"
    end
  end

  describe "no usable id" do
    test "falls through untouched so the working-dir chain can answer" do
      for headers <- [[], [{"x-harness-id", ""}], [{"x-harness-id", "   "}]] do
        conn = call(headers)

        refute conn.halted
        refute Map.has_key?(conn.assigns, :current_scope)
      end
    end

    test "an unexpanded shell variable is absent, not malformed" do
      conn = call([{"x-harness-id", "${CMS_HARNESS_ID}"}])

      refute conn.halted,
             "every checkout has an unset variable until it is onboarded; " <>
               "refusing would take down all its hooks at once"

      refute Map.has_key?(conn.assigns, :current_scope)
    end
  end
end
