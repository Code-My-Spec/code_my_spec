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

  # async: false, not true: two describe blocks below mutate the global
  # Application config :code_my_spec, CodeMySpec.Workspaces (the dev-box
  # harness_source override, and -- elsewhere in this file -- a runner
  # override), restoring it on exit. Every other file that touches this
  # same global key (workspaces_test.exs, the two IntakeLive tests) is
  # already async: false for exactly this reason; this file alone being
  # async: true let its mutation race a concurrently-running async module
  # that reads the same key's default (743ecf1c: "runs from source instead
  # of the installed release", test/code_my_spec/workspaces/
  # a_workspace_claims_its_identity_test.exs:240, failed once under exactly
  # that interleaving).
  use ExUnit.Case, async: false

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

  @preview_env @env ++
                 [
                   {"CMS_PREVIEW_URL", "https://preview-copy-1.codemyspec.com"},
                   {"CMS_PREVIEW_TUNNEL_ID", "tun-1"},
                   {"CMS_PREVIEW_TUNNEL_SECRET", "shh"},
                   {"CMS_PREVIEW_ACCOUNT_TAG", "acct-1"},
                   {"CMS_PREVIEW_EMBEDDER", "https://dev.codemyspec.com"}
                 ]

  # `mix harness.onboard`'s own `put_preview/2` writes these same five keys
  # for a checkout onboarded by hand. Nothing played that part for an
  # instance the server boots itself, so a bare-metal instance never carried
  # them — `enabled: false` in `ClientUtils.CloudflareTunnel`, forever,
  # regardless of anything an agent did. Measured live, 2026-09-21.
  test "and the preview credentials are written when the host minted one", %{dir: dir} do
    :ok = Local.write_identity(dir, @preview_env)

    config = dir |> written() |> File.read!() |> Jason.decode!()

    assert config["preview_url"] == "https://preview-copy-1.codemyspec.com"
    assert config["preview_tunnel_id"] == "tun-1"
    assert config["preview_tunnel_secret"] == "shh"
    assert config["preview_account_tag"] == "acct-1"
    assert config["preview_embedder"] == "https://dev.codemyspec.com"
  end

  test "and no preview keys are written when the host minted no preview", %{dir: dir} do
    :ok = Local.write_identity(dir, @env)

    config = dir |> written() |> File.read!() |> Jason.decode!()

    refute Map.has_key?(config, "preview_url"), """
    An absent preview reads as "not yet provisioned" everywhere else
    (`PreviewLive`, the onboarding task). A blank string here would instead
    read as a checkout that tried and failed.
    """
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

    # Same user-facing failure as ac7a510b (a working application, an agent
    # that never confirms, "nothing here is holding that working copy") from
    # a different cause: `rel/env.sh.eex` names every `cms start` node
    # `codemyspec` by default, so a host that already runs its own `cms
    # harness` — the ordinary state of this very checkout — collides on the
    # very first boot of a workspace here. The harness dies on `epmd`
    # registration while the app keeps answering, which is indistinguishable
    # from healthy until someone messages the agent.
    test "and the harness gets a node name unique to this workspace", %{prepared: p} do
      script = File.read!(p.script_path)

      assert script =~ ~s(export CMS_NODE_NAME="#{name(p)}"), """
      Without CMS_NODE_NAME, every workspace's `cms start` claims the same
      default sname (`codemyspec`) as this machine's own persistent harness —
      the second one to start always loses, silently: the app comes up fine
      and the harness dies on epmd registration, with no trace but this
      workspace's own run.log.
      """
    end

    # A second, independent cause of the identical failure, only visible once
    # the node-name collision above stopped hiding it: the harness can come
    # up cleanly, under its own name, and still never serve this project.
    # `CmsHarness.Projects.start_configured/1`'s moduledoc names the two ways
    # a project gets served — `CMS_PROJECT_DIR` at boot (the sprite path) or a
    # hook from an already-running session (the laptop path) — and a
    # workspace booted here has no developer already sitting in the checkout
    # to fire that first hook, so it needs the sprite path.
    test "and the harness is told which project to serve, at boot", %{prepared: p} do
      script = File.read!(p.script_path)

      assert script =~ ~s(export CMS_PROJECT_DIR="#{p.app_dir}"), """
      Without CMS_PROJECT_DIR the harness starts and sits idle forever: it
      only serves a project because CMS_PROJECT_DIR named it at boot, or
      because a hook from an already-running session picked it up — and
      nothing is already running in a workspace nobody has connected to yet.
      """
    end

    # A customer's own laptop has no code_my_spec checkout to run the
    # harness from, and should not need one — the installed release, on
    # PATH, is the only thing that can be right there. Unconfigured is this
    # case, not an oversight: HarnessSource.Installed is the default.
    test "and it runs the installed release, by default", %{prepared: p} do
      assert File.read!(p.script_path) =~ ~s(export CMS_PROJECT_DIR="#{p.app_dir}"\ncms start &)
    end

    # `VAR=val cmd1 && cmd2` sets VAR only for cmd1 in bash — a real gap this
    # story shipped with, caught live 2026-09-21 against a real customer
    # project: every workspace booted under HarnessSource.Checkout (a
    # compound `cd DIR && mix run` command) silently never received
    # CMS_NODE_NAME, CMS_HARNESS_PORT or CMS_PROJECT_DIR at all — they were
    # prefixed onto `cd`, a builtin that ignores them and does not pass them
    # to what follows `&&`. The harness came up under the default node name
    # and the default port and served nothing, and the failure read exactly
    # like the original node-name and CMS_PROJECT_DIR bugs this story already
    # fixed once. `export` on its own line applies to every later command in
    # the same shell regardless of shape, simple or compound.
    test "the identity variables survive into a compound harness command", %{prepared: p} do
      script = File.read!(p.script_path)

      refute script =~ ~r/CMS_NODE_NAME="[^"]*"\s+cd\s/, """
      An identity variable prefixed directly onto `cd` only sets it for `cd`
      itself — bash does not carry an inline assignment across `&&` into the
      command that follows. Got: #{script}
      """
    end
  end

  # A dev box's own checkout, run straight from source rather than through
  # the separately-released tap `cms` on PATH resolves to. Not a corner case
  # of `prepare/4` — every other identity/naming fix above shares this exact
  # gap once configured this way, since none of them ever reach a bare-metal
  # boot without it: `promote_sync` updates this server, never the installed
  # formula. Measured three weeks stale, missing an Alloy provider a
  # workspace's own agent needed just to restore.
  describe "a dev box running its own checkout" do
    setup do
      original = Application.get_env(:code_my_spec, CodeMySpec.Workspaces, [])

      Application.put_env(
        :code_my_spec,
        CodeMySpec.Workspaces,
        Keyword.put(original, :harness_source, CodeMySpec.Workspaces.HarnessSource.Checkout)
      )

      on_exit(fn -> Application.put_env(:code_my_spec, CodeMySpec.Workspaces, original) end)

      name = "identity-probe-#{System.unique_integer([:positive])}"
      prepared = Local.prepare(name, "demo_app", 4001, @env)
      on_exit(fn -> File.rm_rf(prepared.dir) end)
      %{prepared: prepared}
    end

    test "runs from source instead of the installed release", %{prepared: p} do
      script = File.read!(p.script_path)

      assert script =~
               ~s(export CMS_PROJECT_DIR="#{p.app_dir}"\ncd #{File.cwd!()} && MIX_ENV=harness mix run --no-halt &),
             """
             Left on the default, this dev box's own harness-side fixes never reach a
             bare-metal boot — `promote_sync` updates the server this config lives on,
             not the separately-released tap `cms` resolves to.

             Got: #{script}
             """
    end
  end

  defp name(%{dir: dir}), do: Path.basename(dir)

  # `Workspaces.instance_root/1` calls this instead of assuming the Docker
  # container path (`/workspace/<app>`) so the root the server records
  # actually matches where a bare-metal instance lands — see that function's
  # own docstring for what mismatching them costs (`:working_copy_missing`
  # on agent restore, reported with no hint that a root disagreement is why).
  describe "root/2" do
    test "is where the app directory actually lands under this box's workspace root" do
      assert Local.root("cms-workspace-abc123", "widget_tracker") ==
               Path.join([
                 Path.expand("~/.codemyspec/workspaces"),
                 "cms-workspace-abc123",
                 "widget_tracker"
               ])
    end

    test "honors a configured local_workspace_root rather than always the default" do
      original = Application.get_env(:code_my_spec, CodeMySpec.Workspaces, [])

      Application.put_env(:code_my_spec, CodeMySpec.Workspaces,
        local_workspace_root: "/tmp/custom_root"
      )

      on_exit(fn -> Application.put_env(:code_my_spec, CodeMySpec.Workspaces, original) end)

      assert Local.root("cms-workspace-abc123", "widget_tracker") ==
               "/tmp/custom_root/cms-workspace-abc123/widget_tracker"
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
