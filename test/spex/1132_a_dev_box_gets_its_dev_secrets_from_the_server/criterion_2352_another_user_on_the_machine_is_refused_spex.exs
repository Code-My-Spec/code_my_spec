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

  `Fixtures.unique_age_private_key!/0`, not a literal string shaped like
  a key: `CmsHarness.SopsKeyring` is one process shared by the whole spex
  run, and a malformed entry left in it poisons the identity blob for a
  later, real-decrypt scenario elsewhere in the same run (confirmed, not
  theoretical -- see that fixture's own doc).
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CodeMySpecSpex.Fixtures

  spex "Only the box's own user can reach the key socket at all", criterion: 2352 do
    scenario "a process running as a different user on Sam's machine" do
      given_ "'cloud-1''s harness holds the dev key, with its socket in place", context do
        _rig = app_instance_rig(sops_age_keys: [Fixtures.unique_age_private_key!()])
        eventually(fn -> assert Fixtures.spex_file_exists?(Fixtures.sops_key_socket_path()) end)
        {:ok, context}
      end

      when_ "a process tries to ask the harness for the key", context do
        {:ok, context}
      end

      then_ "it is refused", context do
        socket_path = Fixtures.sops_key_socket_path()
        socket_dir = Path.dirname(socket_path)

        assert Fixtures.spex_file_exists?(socket_path),
               "no socket exists at #{socket_path} for anything to be refused through -- " <>
                 "the permission boundary this criterion is about has nothing to sit on"

        assert Fixtures.spex_user_only?(socket_path),
               "the key socket is reachable by more than its own user, so a different user " <>
                 "on the machine would not be refused at all"

        assert Fixtures.spex_user_only?(socket_dir),
               "the socket's directory is reachable by more than its own user"

        {:ok, context}
      end
    end
  end
end
