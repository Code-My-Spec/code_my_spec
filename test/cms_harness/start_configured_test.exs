defmodule CmsHarness.StartConfiguredTest do
  @moduledoc """
  A sprite's harness serves its working copy at boot, not on the first hook.

  Everything else in `CmsHarness.Projects` starts on demand: a hook names a
  harness id and the subtree comes up to answer it. That is right on a laptop,
  where a session fires a hook within seconds, and the module's own moduledoc
  says so — "Nothing is configured here."

  A sprite is the opposite shape. Its agent has not started yet — `drill.sh`
  waits for "accepted the manifest" *before* running `devbox-agent` — so a
  harness that waits for a hook waits forever, scans nothing, pushes no
  manifest, and looks healthy doing it. Measured: the in-repo harness booted
  clean in a drill container against a real workspace and wrote two lines to
  harness.log, the endpoint starting and its URL (92cffa52).

  `CMS_PROJECT_DIR` is the existing name for this — `sprite.sh` exports it and
  the standalone harness has read it since extraction — so the sprite switches
  over without changing how it is launched.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CmsHarness.Projects

  # Both variables, restored. `CMS_PROJECT_ID` matters more than it looks:
  # `ProjectIdentity.resolve/1` reads it *before* touching disk, and every
  # CodeMySpec checkout's .claude/settings.json exports it for the agent
  # session — so with it set, a nonexistent directory resolves happily and the
  # failure path cannot be reached. The first version of this file asserted an
  # error log that never arrived for exactly that reason. Same ambient leak that
  # sent drill 16 at the wrong project (ca5bf8b6).
  setup do
    saved = %{
      dir: System.get_env("CMS_PROJECT_DIR"),
      id: System.get_env("CMS_PROJECT_ID")
    }

    on_exit(fn ->
      restore("CMS_PROJECT_DIR", saved.dir)
      restore("CMS_PROJECT_ID", saved.id)
    end)

    :ok
  end

  defp restore(var, nil), do: System.delete_env(var)
  defp restore(var, value), do: System.put_env(var, value)

  describe "when nothing is configured" do
    test "it does nothing, which is every laptop" do
      System.delete_env("CMS_PROJECT_DIR")

      assert capture_log(fn -> assert :ok = Projects.start_configured() end) == ""
    end

    test "an empty value counts as unset" do
      # A shell that expanded an unset variable hands over "", not nil. Treating
      # that as a directory would resolve against the filesystem root.
      System.put_env("CMS_PROJECT_DIR", "")

      assert capture_log(fn -> assert :ok = Projects.start_configured() end) == ""
    end
  end

  describe "when a directory is configured but cannot be served" do
    test "it says so loudly and still returns :ok" do
      System.delete_env("CMS_PROJECT_ID")
      System.put_env("CMS_PROJECT_DIR", "/nonexistent/#{System.unique_integer([:positive])}")

      log = capture_log([level: :error], fn -> assert :ok = Projects.start_configured() end)

      assert log =~ "CMS_PROJECT_DIR"
      assert log =~ "could not serve it"

      # Matched on a fragment that does not span a line break — the message is a
      # wrapped heredoc, so asserting a whole sentence tests the wrapping rather
      # than the content, and fails when someone reflows a comment.
      assert log =~ "manifest that will never be sent",
             "on a sprite this is fatal in practice, and the message has to say which end is stuck"
    end

    test "a failure does not take the harness down" do
      # Deliberate. A working copy that cannot be served is worth shouting
      # about, but a hook naming a *different* copy can still be answered, and a
      # harness that refuses to start answers nothing at all.
      System.delete_env("CMS_PROJECT_ID")
      System.put_env("CMS_PROJECT_DIR", "/nonexistent/#{System.unique_integer([:positive])}")

      capture_log(fn ->
        assert :ok = Projects.start_configured()
        assert :ok = Projects.start_configured()
      end)
    end
  end
end
