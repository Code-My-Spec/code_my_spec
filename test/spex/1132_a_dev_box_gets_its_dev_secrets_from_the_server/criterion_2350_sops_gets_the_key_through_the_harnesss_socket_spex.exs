defmodule CodeMySpecSpex.Story1132.Criterion2350Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2350 -- sops gets the key through the harness's socket.

  Brings up a real harness via `app_instance_rig/1` (the same rig
  criterion 2339 drives), configured to receive a dev key on join, then
  checks for the Unix domain socket the story's own notes name
  (`~/.codemyspec/run/key.sock`) -- the one place `sops`'s key command is
  meant to reach the harness through. There is nothing at that path yet:
  this story has not built the socket listener, only decided where it
  should live.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CodeMySpecSpex.Fixtures

  spex "The harness serves its key over a Unix domain socket, not HTTP", criterion: 2350 do
    scenario "'cloud-1''s harness holds the dev key" do
      given_ "'cloud-1''s harness holds the dev key", context do
        rig = app_instance_rig(sops_age_keys: ["AGE-SECRET-KEY-1DEV"])
        Process.sleep(300)
        {:ok, Map.put(context, :rig, rig)}
      end

      when_ "sops runs the key command as the box's user", context do
        socket_path = Path.expand("~/.codemyspec/run/key.sock")
        {:ok, Map.put(context, :socket_path, socket_path)}
      end

      then_ "the key command reaches the harness through its socket, which only that user can open",
            context do
        assert Fixtures.spex_file_exists?(context.socket_path),
               "no socket exists at #{context.socket_path} for the key command to reach the " <>
                 "harness through -- the harness holds a key but serves it nowhere"

        {:ok, context}
      end

      then_ "sops decrypts", context do
        assert Fixtures.spex_file_exists?(context.socket_path),
               "with no socket to connect through, sops has no way to decrypt anything with " <>
                 "this harness's key"

        {:ok, context}
      end
    end
  end
end
