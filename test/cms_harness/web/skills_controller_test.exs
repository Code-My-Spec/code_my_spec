defmodule CmsHarness.Web.SkillsControllerTest do
  @moduledoc """
  `4396345b`: the surface every `skills/*/skill.md` posts to. Same shape as
  `HooksControllerTest` — a real answer when a served copy asks, a clean
  refusal (never a 415, never a crash) when it cannot be answered.
  """

  use CmsHarnessTest.ConnCase, async: false

  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.Projects
  alias CmsHarnessTest.FakeServer

  setup do
    previous = System.get_env("CMS_PROJECT_ID")
    System.delete_env("CMS_PROJECT_ID")

    on_exit(fn -> restore_project_id(previous) end)

    project = project_dir()
    serve(project.root)
    on_exit(fn -> stop_project(project.root) end)

    %{project: project}
  end

  describe "with no connection to the server" do
    test "a skill start is refused, not crashed on", %{conn: conn, project: project} do
      body = conn |> post_skill(project.root, %{"skill" => "qa"}) |> json_response(200)

      assert body["error"]
      refute Map.has_key?(body, "prompt")
    end
  end

  describe "with no project to serve" do
    test "a copy this harness does not serve is refused by id, in a sentence", %{conn: conn} do
      id = Ecto.UUID.generate()
      body = conn |> post_skill_as(id, %{"skill" => "qa"}) |> json_response(200)

      # Was `body["error"] in ["unknown_harness", "server_unreachable"]`. A bare
      # code is not an answer: a skill.md pipes this straight into the agent's
      # context, so it is the whole error experience and there is nowhere else
      # to look. `6c93a317` is a session lost to exactly that.
      assert body["error"] =~ "could not start this skill"

      assert body["error"] =~ id,
             "naming the id is what separates 'your config points somewhere wrong' " <>
               "from 'the server is down', which need opposite responses"
    end

    # Renamed. This posts the literal `unonboarded`, which is not "no harness id
    # at all" — it is the fallback in `${HID:-unonboarded}` that every skill.md
    # uses when `.cms_harness.json` is missing or has no `harness_id`. The old
    # name described a case this request does not make, and the assertion passed
    # for either.
    test "a copy that was never onboarded is told to onboard", %{conn: conn} do
      body =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/harnesses/unonboarded/skills/start", %{"skill" => "qa"})
        |> json_response(200)

      assert body["error"] =~ "has not been onboarded"
      assert body["error"] =~ "mix cms.harness.onboard"

      refute body["error"] =~ "not serving",
             "the unknown-harness wording sends the reader to check an id against " <>
               "the server, and there is no id here — nothing was ever written"

      assert body["error"] =~ "MCP tools",
             "the workaround several agents found on their own belongs in the message"
    end
  end

  describe "serving a project" do
    setup %{project: project} do
      stop_project(project.root)
      FakeServer.start(skill_reply: %{"prompt" => "do the thing"})
      :ok
    end

    test "the server's prompt comes back to the caller", %{conn: conn, project: project} do
      {:ok, _} = Projects.ensure_started(project.root)
      assert await_connected(project.root)

      body = conn |> post_skill(project.root, %{"skill" => "qa"}) |> json_response(200)

      assert body["prompt"] == "do the thing"
    end

    test "the params the harness got are what the skill.md sent, unmangled", %{
      conn: conn,
      project: project
    } do
      {:ok, _} = Projects.ensure_started(project.root)
      assert await_connected(project.root)

      conn
      |> post_skill(project.root, %{"skill" => "qa", "arguments" => "story 42"})
      |> json_response(200)

      assert_received {:skill_start, %{"params" => %{"skill" => "qa", "arguments" => "story 42"}}}
    end
  end

  defp await_connected(root, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      halt_when_connected(ChannelClient.connected?(root))
    end)
  end

  defp restore_project_id(nil), do: :ok
  defp restore_project_id(previous), do: System.put_env("CMS_PROJECT_ID", previous)

  defp halt_when_connected(true), do: {:halt, true}

  defp halt_when_connected(false) do
    Process.sleep(50)
    {:cont, false}
  end
end
