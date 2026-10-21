defmodule CodeMySpecSpex.Story1132.Criterion2350Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2350 -- sops gets the key through the harness's socket.

  Brings up a real harness via `app_instance_rig/1` (the same rig
  criterion 2339 drives), configured to receive a dev key on join, then
  drives the real, installed `sops` against a file encrypted to that same
  key -- the same round trip criterion 2346 drives, checked here from the
  socket's own side: the socket exists at the path the story names, and
  `sops` genuinely decrypts through it.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CodeMySpecSpex.Fixtures

  spex "The harness serves its key over a Unix domain socket, not HTTP", criterion: 2350 do
    scenario "'cloud-1''s harness holds the dev key" do
      given_ "'cloud-1''s harness holds the dev key", context do
        dir = Fixtures.spex_tmp_dir!("sops-socket-spex")
        {pub, priv} = Fixtures.age_keypair!(dir)
        enc_path = Fixtures.sops_encrypt_dotenv!(dir, "test.enc.env", "SECRET=whatever\n", pub)

        _rig = app_instance_rig(sops_age_keys: [priv])
        eventually(fn -> assert Fixtures.harness_holding_key?(priv) end)

        {:ok, Map.put(context, :enc_path, enc_path)}
      end

      when_ "sops runs the key command as the box's user", context do
        result =
          Fixtures.sops_decrypt_dotenv(context.enc_path,
            env: [{"SOPS_AGE_KEY_CMD", Fixtures.sops_key_shim_path!()}]
          )

        {:ok, Map.put(context, :result, result)}
      end

      then_ "the key command reaches the harness through its socket, which only that user can open",
            context do
        assert Fixtures.spex_file_exists?(Fixtures.sops_key_socket_path()),
               "no socket exists at #{Fixtures.sops_key_socket_path()} for the key command to " <>
                 "reach the harness through"

        {:ok, context}
      end

      then_ "sops decrypts", context do
        assert {:ok, "SECRET=whatever\n"} = context.result,
               "sops did not decrypt through the harness's socket:\n\n#{inspect(context.result)}"

        {:ok, context}
      end
    end
  end
end
