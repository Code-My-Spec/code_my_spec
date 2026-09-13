defmodule CmsHarness.Web.RejoinControllerTest do
  @moduledoc """
  One copy's channel drops and joins again, and nothing else on the machine
  moves.

  `handle_join/3` is the only place the `agents_to_restore` handshake runs, so
  until this the only way to see it was a harness restart — one process serving
  every checkout, which is why `0fb7bf03` records five QA passes in a row
  declining to observe the thing story 1014's criteria 3304 and 3305 are
  entirely about.

  So the assertion that matters is not that the rejoin happened. It is the
  second copy: after this route runs, a copy that was not named is still served
  and still connected. A rejoin that took the machine with it would satisfy
  every other assertion here and be exactly the tool nobody could use.
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

  describe "with an id nothing accounts for" do
    test "a server that could not be asked is not reported as a wrong id", %{conn: conn} do
      id = Ecto.UUID.generate()
      body = conn |> post_rejoin_as(id) |> response(503)

      assert body =~ "could not reach the CodeMySpec server"
      assert body =~ id
    end
  end

  describe "serving a project" do
    setup %{project: project} do
      stop_project(project.root)
      FakeServer.start()
      :ok
    end

    test "the copy is serving again after it rejoins", %{conn: conn, project: project} do
      {:ok, _} = Projects.ensure_started(project.root)
      assert await_connected(project.root)

      body = conn |> post_rejoin(project.root) |> response(200)

      assert body =~ "Rejoined"

      assert await_connected(project.root), """
      The channel went down and did not come back, so this route is a way to
      stop serving a copy rather than a way to reconnect one.
      """
    end

    test "and the copy nobody named is untouched", %{conn: conn, project: project} do
      other = project_dir()
      serve(other.root)
      on_exit(fn -> stop_project(other.root) end)

      {:ok, _} = Projects.ensure_started(project.root)
      {:ok, _} = Projects.ensure_started(other.root)
      assert await_connected(project.root)
      assert await_connected(other.root)

      conn |> post_rejoin(project.root) |> response(200)

      assert ChannelClient.connected?(other.root), """
      Rejoining one copy dropped another. That is the harness restart this
      exists to replace — one process serves every checkout, and taking them all
      down to see one reconnect is the cost that made these criteria untestable
      in the first place (0fb7bf03).
      """
    end

    test "a copy this machine does not serve is refused by id", %{conn: conn} do
      id = Ecto.UUID.generate()
      body = conn |> post_rejoin_as(id) |> response(404)

      assert body =~ "does not serve harness id"
      assert body =~ id
    end
  end

  defp post_rejoin(conn, root), do: post_rejoin_as(conn, working_copy_id_at(root))

  defp post_rejoin_as(conn, working_copy_id) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/api/harnesses/#{working_copy_id}/rejoin", %{})
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
