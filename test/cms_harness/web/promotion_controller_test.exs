defmodule CmsHarness.Web.PromotionControllerTest do
  @moduledoc """
  Promotion's external door: the URL a caller with no conversation blocks on.

  Same shape as `SkillsControllerTest` — a real answer when a served copy asks,
  a clean refusal (never a crash) when it cannot be answered — plus the one
  thing that is specific to this surface: `curl` exits 0 whichever way the gate
  went, so the footer is the only thing separating a promotion from a refusal,
  and a caller that reads it wrongly sends QA at code that never crossed.
  """

  use CmsHarnessTest.ConnCase, async: false

  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.Projects
  alias CmsHarnessTest.FakeServer

  setup do
    project = project_dir()
    serve(project.root)
    on_exit(fn -> stop_project(project.root) end)

    %{project: project}
  end

  describe "with no connection to the server" do
    test "a promotion is refused, not crashed on", %{conn: conn, project: project} do
      body = conn |> post_promotion(project.root) |> response(502)

      assert body =~ "could not promote"
      assert body =~ "exit status: 1"
    end
  end

  describe "with an id nothing accounts for" do
    # 503 rather than 404, and the difference is the whole point. Re-onboarding
    # fixes a wrong id and fixes nothing here; collapsing the two sent the
    # refusal's reader to re-run `mix cms.harness.onboard` on an id that was
    # already correct. There is no credential in this environment, so the
    # harness cannot ask the server where the copy is.
    test "a server that could not be asked is not reported as a wrong id", %{conn: conn} do
      id = Ecto.UUID.generate()
      body = conn |> post_promotion_as(id) |> response(503)

      assert body =~ "could not reach the CodeMySpec server"
      assert body =~ id
      assert body =~ "exit status: 1"
    end
  end

  describe "serving a project" do
    setup %{project: project} do
      stop_project(project.root)
      FakeServer.start()
      :ok
    end

    test "the server's report comes back to the caller", %{conn: conn, project: project} do
      {:ok, _} = Projects.ensure_started(project.root)
      assert await_connected(project.root)

      FakeServer.put_promotion_reply(%{
        "status" => "promoted",
        "report" => "Promoted feature/promote-url to the running dev copy."
      })

      body = conn |> post_promotion(project.root) |> response(200)

      assert body =~ "Promoted feature/promote-url to the running dev copy."
      assert body =~ "── promotion: promoted ──"
      assert body =~ "exit status: 0"
    end

    # The one distinction the footer exists for. A refused gate answers 200 —
    # the promotion ran and declined, which is it working — so the status line
    # is all a caller has, and reporting it as a success would put QA in front
    # of an application that never got the work.
    test "a refusal is an answer, with a non-zero exit status", %{conn: conn, project: project} do
      {:ok, _} = Projects.ensure_started(project.root)
      assert await_connected(project.root)

      FakeServer.put_promotion_reply(%{
        "status" => "refused",
        "report" => "this copy is carrying 3 problem(s), so it promotes nothing"
      })

      body = conn |> post_promotion(project.root) |> response(200)

      assert body =~ "carrying 3 problem(s)"
      assert body =~ "── promotion: refused ──"
      assert body =~ "exit status: 1"
    end

    # An older server has no clause for this event and answers `unknown_event`.
    # That is version skew, not a promotion that refused, and it must not read
    # as one — a caller told "refused" goes looking for problems to fix.
    test "a server that does not implement the event is not a refusal", %{
      conn: conn,
      project: project
    } do
      {:ok, _} = Projects.ensure_started(project.root)
      assert await_connected(project.root)

      FakeServer.put_promotion_reply({:error, %{"reason" => "unknown_event"}})

      body = conn |> post_promotion(project.root) |> response(502)

      assert body =~ "unknown_event"
      assert body =~ "not attempted"
    end

    # The server is reachable here and says it has never heard of this id, which
    # is the case re-onboarding actually fixes — distinct from the 503 above.
    test "a copy this machine does not serve is refused by id", %{conn: conn} do
      id = Ecto.UUID.generate()
      body = conn |> post_promotion_as(id) |> response(404)

      assert body =~ "does not serve harness id"

      assert body =~ id,
             "naming the id is what separates 'your config points somewhere wrong' " <>
               "from 'the server is down', which need opposite responses"

      assert body =~ "exit status: 1"
    end

    test "the event reaches the server addressed to this working copy", %{
      conn: conn,
      project: project
    } do
      {:ok, _} = Projects.ensure_started(project.root)
      assert await_connected(project.root)

      conn |> post_promotion(project.root) |> response(200)

      assert_received {:promotion_run, project_id, _payload}
      assert project_id == project.id
    end
  end

  defp post_promotion(conn, root), do: post_promotion_as(conn, working_copy_id_at(root))

  defp post_promotion_as(conn, working_copy_id) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/api/harnesses/#{working_copy_id}/promotion/run", %{})
  end

  defp await_connected(root, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      halt_when_connected(ChannelClient.connected?(root))
    end)
  end

  defp halt_when_connected(true), do: {:halt, true}

  defp halt_when_connected(false) do
    Process.sleep(50)
    {:cont, false}
  end
end
