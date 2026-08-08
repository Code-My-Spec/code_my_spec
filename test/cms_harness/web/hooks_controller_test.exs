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
    serve(project.root)
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
    test "a copy this harness does not serve is refused by id", %{conn: conn} do
      body = conn |> post_hook_as("stop", Ecto.UUID.generate()) |> json_response(200)

      assert body["decision"] == "block"

      assert body["reason"] =~ "not serving the working copy",
             "an id nobody onboarded resolves to nothing — the alternative was " <>
               "walking up from the request's directory until a mix.exs turned up, " <>
               "which adopted whichever project sat above an unonboarded checkout"
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
    setup %{project: project} do
      # The outer setup already served this copy, so its channel is retrying
      # against a server that did not exist yet. Stop it before the fake comes
      # up; the tests below start it again and it finds one.
      stop_project(project.root)
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
    test "a hook addressed to a served copy is answered for that copy", %{
      conn: conn,
      project: project
    } do
      assert project.root in CmsHarness.Projects.list()

      body = conn |> post_hook("stop", project.root) |> json_response(200)

      assert is_map(body),
             "the id named a copy this harness serves, so it got a real answer — " <>
               "what this replaced picked the copy up from whatever directory the " <>
               "hook announced, which is how a nested checkout resolved to the outer one"
    end
  end
end
