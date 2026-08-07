defmodule CmsHarness.Web.HooksControllerTest do
  @moduledoc """
  The hook surface with no server on the other end — which is the state that
  matters, because it is the one where a wrong answer is invisible.
  """

  use CmsHarnessTest.ConnCase, async: false

  alias CmsHarnessTest.FakeServer

  setup do
    previous = System.get_env("CMS_PROJECT_ID")
    System.delete_env("CMS_PROJECT_ID")

    on_exit(fn ->
      if previous, do: System.put_env("CMS_PROJECT_ID", previous)
    end)

    project = project_dir()
    on_exit(fn -> stop_project(project.root) end)

    %{project: project}
  end

  describe "with no connection to the server" do
    test "a stop is blocked, and the reason names the harness", %{conn: conn, project: project} do
      body = conn |> post_hook("stop", project.root) |> json_response(200)

      assert body["decision"] == "block"
      assert body["reason"] =~ "harness"
      assert body["reason"] =~ "never got to ask"
    end

    # Blocking is only half the job. A refusal that misdiagnoses sends whoever
    # reads it to the wrong place, and this one did: with no credential the
    # client never connected, but the hook path only knew `joined: false` and
    # reported the *channel* as down — so the message said to go and check the
    # network and the server, when the fix was to set an environment variable.
    #
    # The wording of each reason was already tested. What was not was which
    # reason gets picked, which is where it went wrong.
    test "with no credential it says so, rather than blaming the connection",
         %{conn: conn, project: project} do
      body = conn |> post_hook("stop", project.root) |> json_response(200)

      assert body["decision"] == "block"

      assert body["reason"] =~ "CMS_TOKEN",
             "a harness with no credential has to name the credential, not the network"

      refute body["reason"] =~ "channel to the CodeMySpec server is down",
             "that is a different failure with a different fix"
    end

    test "a subagent-stop is blocked too", %{conn: conn, project: project} do
      body = conn |> post_hook("subagent-stop", project.root) |> json_response(200)

      assert body["decision"] == "block"
    end

    test "a session-start is not blocked, only reported", %{conn: conn, project: project} do
      body = conn |> post_hook("session-start", project.root) |> json_response(200)

      refute Map.has_key?(body, "decision")
      assert body["systemMessage"] =~ "not connected"
    end
  end

  describe "with no project to serve" do
    test "a directory with no id is refused, and told where to put one", %{conn: conn} do
      body = conn |> post_hook("stop", anonymous_dir()) |> json_response(200)

      assert body["decision"] == "block"
      assert body["reason"] =~ ".code_my_spec/config.yml"
    end

    test "a hook with no working directory at all is refused", %{conn: conn} do
      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/hooks/stop", %{})
        |> json_response(200)

      assert body["decision"] == "block"
    end
  end

  describe "the two answers stay distinguishable" do
    # The whole point, stated as a test: a harness that could not ask must not
    # be able to produce the response a harness that asked and heard "nothing to
    # do" produces.
    test "a refusal is not an empty allow", %{conn: conn, project: project} do
      body = conn |> post_hook("stop", project.root) |> json_response(200)

      refute body == %{}
      assert body["decision"] == "block"
    end
  end

  # The reply most hooks actually get, and the one that was broken.
  #
  # post-tool-use, notification and ask-user-question all answer {200, %{}}, and
  # so does stop whenever nothing blocks it — which is every clean turn. Phoenix
  # sends %{"status" => "ok", "response" => %{}} and Slipstream collapses an
  # empty response to the bare atom :ok, which the harness read as an unreadable
  # shape and refused. On post-tool-use that is every tool call.
  #
  # Testable here only because FakeServer is a real channel over a real socket;
  # the collapse does not happen anywhere a reply is passed as a term.
  describe "an empty decision" do
    setup do
      FakeServer.start(hook_decision: %{})
      :ok
    end

    test "means nothing to say, not something unreadable", %{conn: conn, project: project} do
      {:ok, _} = CmsHarness.Projects.ensure_started(project.root)
      assert await_connected(project.root)

      body = conn |> post_hook("stop", project.root) |> json_response(200)

      refute Map.has_key?(body, "decision"),
             "an empty decision means nothing blocks this stop — refusing it means an " <>
               "agent with nothing left to do can never say so"

      refute body["reason"], "an empty decision carries no refusal reason — the harness did ask"
    end

    test "post-tool-use is not refused on every tool call", %{conn: conn, project: project} do
      {:ok, _} = CmsHarness.Projects.ensure_started(project.root)
      assert await_connected(project.root)

      body = conn |> post_hook("post-tool-use", project.root) |> json_response(200)

      refute Map.has_key?(body, "decision")
      refute Map.has_key?(body, "systemMessage")
    end
  end

  defp await_connected(root, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if CmsHarness.Project.ChannelClient.connected?(root) do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end

  describe "serving a project" do
    test "a hook for an unknown directory starts serving it", %{conn: conn, project: project} do
      refute project.root in CmsHarness.Projects.list()

      conn |> post_hook("stop", project.root) |> json_response(200)

      assert project.root in CmsHarness.Projects.list(),
             "a laptop picks its projects up from the hooks that arrive, not from a list " <>
               "somebody has to maintain"
    end
  end
end
