defmodule CmsHarness.Web.HookCwdResolutionTest do
  @moduledoc """
  A hook that names no id is resolved from the `cwd` already in its payload.

  This is what lets a hook command be a plain curl with nothing interpolated
  into it. Today there are three implementations of one walk — `bin/hook`
  (bash), `hook.cmd`, `hook.ps1` — because the client had to compute an identity
  before it could send one, and the bash one's own comment calls needing Git
  Bash on Windows "a regression from the `curl` this replaced".

  It is safe because of what the path is used for. The design that was removed
  had the *server* map a path to a working copy, where "a wrong path did not
  fail — it succeeded against the wrong disk". Here a path only locates the file
  that states an identity, on the machine that path is on, and a path that finds
  no file is refused rather than guessed at. See `CmsHarness.WorkingCopyWalk`.
  """
  use CmsHarnessTest.ConnCase, async: false

  alias CmsHarnessTest.Projects

  setup do
    previous = System.get_env("CMS_PROJECT_ID")
    System.delete_env("CMS_PROJECT_ID")
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: :ok
  defp restore(value), do: System.put_env("CMS_PROJECT_ID", value)

  defp post_hook(conn, body) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/api/hooks/stop", body)
  end

  # `stop` decides, so a refusal comes back as `decision`/`reason` rather than
  # `systemMessage` — `HookDecision.unreachable/4` picks by hook. Reading both
  # keeps the assertions about *what was said* rather than which envelope.
  defp said(response) do
    body = json_response(response, 200)
    body["reason"] || body["systemMessage"] || ""
  end

  test "a payload's cwd resolves the working copy with no id sent at all", %{conn: conn} do
    project = Projects.project_dir()
    on_exit(fn -> Projects.stop_project(project.root) end)

    said = said(post_hook(conn, %{"hook_event_name" => "Stop", "cwd" => project.root}))

    # Not connected to a server here, so the decision is a refusal — but it must
    # be a refusal *about this working copy*, which means the cwd resolved. A
    # request that resolved nothing says so in different words.
    refute said =~ "did not say which working copy",
           "the cwd was in the payload and was not used"
  end

  test "a subdirectory resolves the same as the root", %{conn: conn} do
    project = Projects.project_dir()
    on_exit(fn -> Projects.stop_project(project.root) end)
    deep = Path.join([project.root, "lib", "deep"])
    File.mkdir_p!(deep)

    from_root = said(post_hook(conn, %{"cwd" => project.root}))
    from_deep = said(post_hook(conn, %{"cwd" => deep}))

    assert from_root == from_deep,
           "a hook fires wherever the agent happens to be — that must not change " <>
             "which working copy it is about"
  end

  test "an un-onboarded project is named, not adopted from its parent", %{conn: conn} do
    bare = Path.join(System.tmp_dir!(), "bare_#{System.unique_integer([:positive])}")
    File.mkdir_p!(bare)
    File.write!(Path.join(bare, "mix.exs"), "defmodule X do end")
    on_exit(fn -> File.rm_rf!(bare) end)

    said = said(post_hook(conn, %{"cwd" => bare}))

    assert said =~ "has not been onboarded"

    assert said =~ bare,
           "the refusal has to name the directory to run onboard in — the reader " <>
             "is looking at a hook that failed, not at this code"
  end

  test "an explicit id still wins over the cwd", %{conn: conn} do
    project = Projects.project_dir()
    on_exit(fn -> Projects.stop_project(project.root) end)

    said =
      conn
      |> Plug.Conn.put_req_header("x-harness-id", Ecto.UUID.generate())
      |> post_hook(%{"cwd" => project.root})
      |> said()

    refute said =~ "has not been onboarded",
           "a request that names a working copy is more specific than one that " <>
             "only says where it fired"
  end

  test "no id and no cwd is still refused", %{conn: conn} do
    said = said(post_hook(conn, %{"hook_event_name" => "Stop"}))

    assert said != "", "a hook that resolved nothing still has to answer"
  end
end
