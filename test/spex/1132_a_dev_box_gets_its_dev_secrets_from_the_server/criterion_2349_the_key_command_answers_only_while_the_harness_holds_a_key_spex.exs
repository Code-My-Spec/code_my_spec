defmodule CodeMySpecSpex.Story1132.Criterion2349Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2349 -- The key command answers only while the harness holds a key.

  Drives the real `sops`, the same way criterion 2346 does, but with no
  harness running at all -- the clearest real instance of "the harness is
  not connected" available to a spex, since standing up a real harness and
  then disconnecting it is what criterion 2345 already covers for the
  revoked-box case. There being no key command built yet either, this
  fails before it can reach the distinction the criterion is actually
  about (no key held, vs. no key command at all).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  spex "Without a harness holding a key, the key command answers nothing and says why",
    criterion: 2349 do
    scenario "'cloud-1''s harness is not connected" do
      given_ "'cloud-1''s harness is not connected", context do
        dir = Fixtures.spex_tmp_dir!("sops-no-key-spex")
        {pub, _priv} = Fixtures.age_keypair!(dir)
        enc_path = Fixtures.sops_encrypt_dotenv!(dir, "test.enc.env", "SECRET=whatever\n", pub)
        {:ok, Map.put(context, :enc_path, enc_path)}
      end

      when_ "sops runs the key command", context do
        result =
          Fixtures.sops_decrypt_dotenv(context.enc_path,
            env: [{"SOPS_AGE_KEY_CMD", "cms sops-key"}]
          )

        {:ok, Map.put(context, :result, result)}
      end

      then_ "it gets no key and sops fails to decrypt, saying why", context do
        assert {:error, output} = context.result,
               "sops decrypted without a harness connected to hold the key at all"

        refute output == "", "a failed decrypt said nothing about why it failed"

        {:ok, context}
      end
    end
  end
end
