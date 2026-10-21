defmodule CodeMySpecSpex.Story1132.Criterion2352Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2352 -- Another user on the machine is refused.

  A spex runs as one OS user, so it cannot literally become "a different
  user" to prove a connection attempt is refused. What it can check is the
  thing the story's own notes say does the refusing: file permissions
  ("a 0700 directory with the socket at 0600, so file permissions limit it
  to the box user"). Those bits are what the kernel itself enforces
  against every other user on the machine, so checking them is checking
  the actual mechanism, not a stand-in for it.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CodeMySpecSpex.Fixtures

  @socket_dir Path.expand("~/.codemyspec/run")
  @socket_path Path.join(@socket_dir, "key.sock")

  spex "Only the box's own user can reach the key socket at all", criterion: 2352 do
    scenario "a process running as a different user on Sam's machine" do
      given_ "'cloud-1''s harness holds the dev key, with its socket in place", context do
        rig = app_instance_rig(sops_age_keys: ["AGE-SECRET-KEY-1DEV"])
        Process.sleep(300)
        {:ok, Map.put(context, :rig, rig)}
      end

      when_ "a process tries to ask the harness for the key", context do
        {:ok, context}
      end

      then_ "it is refused", context do
        assert Fixtures.spex_file_exists?(@socket_path),
               "no socket exists at #{@socket_path} for anything to be refused through -- " <>
                 "the permission boundary this criterion is about has nothing to sit on"

        assert Fixtures.spex_user_only?(@socket_path),
               "the key socket is reachable by more than its own user, so a different user " <>
                 "on the machine would not be refused at all"

        assert Fixtures.spex_user_only?(@socket_dir),
               "the socket's directory is reachable by more than its own user"

        {:ok, context}
      end
    end
  end
end
