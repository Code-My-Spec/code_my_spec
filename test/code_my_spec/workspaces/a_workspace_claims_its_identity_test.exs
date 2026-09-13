defmodule CodeMySpec.Workspaces.AWorkspaceClaimsItsIdentityTest do
  @moduledoc """
  A workspace the host minted an id for comes up owning that id.

  Issue `ac7a510b`, critical, from a paying customer's first run. The container
  booted and the app was reachable; the project's agent never started. Nine
  minutes of "Getting ready. It will start work as soon as its machine picks it
  up", a working-copies page reading "Not being served" and "1 agent asked for,
  none confirmed yet", and a message to the agent refused with "a copy on a new
  project usually has no deploy key of its own yet".

  `Workspaces.instance_env/1` had already minted the id and assembled the deploy
  key and server url, and handed them to `Runner.start/4`. `Runner.Local` named
  the parameter `_env` and dropped it, where `docker/devbox/entrypoint.sh` uses
  the same values.

  Written to `.cms_harness.json` rather than exported, because that is the only
  thing identity is read from — `HarnessConfig`'s own words: "The file is the
  answer, and the only one — no environment fallback, not even when there is no
  file at all", after the env winning collapsed every root onto one id.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Workspaces.Runner.Local

  @env [
    {"CMS_WORKING_COPY_ID", "copy-1"},
    {"CMS_PROJECT_ID", "proj-1"},
    {"CMS_DEPLOY_KEY", "dk_the_secret"},
    {"CMS_SERVER_URL", "https://dev.example.com"}
  ]

  setup do
    %{dir: CodeMySpec.TempFile.owned_dir("workspace_identity")}
  end

  defp written(dir), do: Path.join(dir, ".cms_harness.json")

  test "the host's identity is written where the copy will read it", %{dir: dir} do
    :ok = Local.write_identity(dir, @env)

    assert File.exists?(written(dir)), """
    Nothing claims the copy, so it is never served and the agent asked for on it
    is never confirmed — ac7a510b.
    """

    config = dir |> written() |> File.read!() |> Jason.decode!()

    assert config["working_copy_id"] == "copy-1"
    assert config["project_id"] == "proj-1"
    assert config["deploy_key"] == "dk_the_secret"
    assert config["server_url"] == "https://dev.example.com"
  end

  test "and it is not world-readable, because it carries a deploy key", %{dir: dir} do
    :ok = Local.write_identity(dir, @env)

    %File.Stat{mode: mode} = File.stat!(written(dir))

    assert Bitwise.band(mode, 0o077) == 0, """
    A file holding a deploy key was readable by other accounts on the machine.
    That is a key that has to be rotated, which is b1d87f01 by another route.
    """
  end

  # `instance_env/1` answers with string-keyed 2-tuples, not a keyword list.
  # `env[:CMS_WORKING_COPY_ID]` finds nothing there, and finds it silently.
  test "string-keyed tuples are read, not just keyword lists", %{dir: dir} do
    :ok = Local.write_identity(dir, [{"CMS_WORKING_COPY_ID", "copy-2"}])

    assert dir |> written() |> File.read!() |> Jason.decode!() |> Map.get("working_copy_id") ==
             "copy-2"
  end

  # The wiring, not the function. Blinding `write_identity/2`'s call site left
  # every test above green — `prepare/4` is what `start/4` does before it
  # launches anything, so it can be driven without spawning a real workspace.
  describe "preparing a workspace" do
    setup do
      name = "identity-probe-#{System.unique_integer([:positive])}"
      prepared = Local.prepare(name, "demo_app", 4001, @env)
      on_exit(fn -> File.rm_rf(prepared.dir) end)
      %{prepared: prepared}
    end

    test "writes the identity the host minted", %{prepared: p} do
      assert File.exists?(Path.join(p.dir, ".cms_harness.json")),
             "start/4 prepares a workspace that claims nothing, which is ac7a510b"
    end

    test "and the script moves it to where the application will be", %{prepared: p} do
      script = File.read!(p.script_path)

      assert script =~ ~s(mv "#{p.dir}/.cms_harness.json" "#{p.app_dir}/.cms_harness.json"), """
      HarnessConfig.path/1 looks in the application root and does not walk up, so
      an identity left beside the workspace is an identity nothing reads.
      """
    end

    test "and the deploy key is never written into the script", %{prepared: p} do
      refute File.read!(p.script_path) =~ "dk_the_secret", """
      run.sh is readable by anyone on the machine. A key that reaches it is a key
      that has to be rotated.
      """
    end
  end

  describe "when the host named nothing" do
    test "no file is written and the workspace still boots", %{dir: dir} do
      assert :ok = Local.write_identity(dir, [])

      refute File.exists?(written(dir)), """
      An empty identity file is worse than none: it is a copy claiming to be
      nobody, where absent means "started by hand, un-onboarded" — which the
      container path treats as legitimate and so must this.
      """
    end

    test "and a non-list env is not a crash", %{dir: dir} do
      assert :ok = Local.write_identity(dir, {:error, :no_account})

      refute File.exists?(written(dir)),
             "instance_env/1 can answer {:error, reason}; booting must not die on it"
    end
  end
end
