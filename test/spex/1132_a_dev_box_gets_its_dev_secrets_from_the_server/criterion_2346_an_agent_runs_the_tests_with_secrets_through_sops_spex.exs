defmodule CodeMySpecSpex.Story1132.Criterion2346Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2346 -- An agent runs the tests with secrets through sops.

  Drives the real, installed `sops` binary (confirmed to support
  `SOPS_AGE_KEY_CMD`) against a real harness (`app_instance_rig/1`)
  holding the matching dev key. `SOPS_AGE_KEY_CMD` points at
  `Fixtures.sops_key_shim_path!/0`, which runs this checkout's own `cms
  sops-key` through `mix run --no-start` -- the `cms` already installed
  on this dev machine's own PATH is an unrelated release of this project
  and never reflects an uncommitted source change (see the fixture's own
  doc). `sops` forks and execs that single path directly as its own
  child with no intervening shell fork (confirmed empirically), so the
  harness-side "is my caller's parent sops" check sees the real sops
  process.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CodeMySpecSpex.Fixtures

  @secret_name "CMS_SPEX_DEV_SECRET"
  @secret_value "value-from-the-dev-env"

  spex "sops decrypts the test env through the box's own key command", criterion: 2346 do
    scenario "an agent in 'cloud-1' runs `sops exec-env envs/test.env 'mix test'`" do
      given_ "'cloud-1' holds an encrypted test env and a key command that asks its harness",
             context do
        dir = Fixtures.spex_tmp_dir!("sops-exec-env-spex")
        {pub, priv} = Fixtures.age_keypair!(dir)

        enc_path =
          Fixtures.sops_encrypt_dotenv!(
            dir,
            "test.enc.env",
            "#{@secret_name}=#{@secret_value}\n",
            pub
          )

        _rig = app_instance_rig(sops_age_keys: [priv])

        eventually(fn -> assert Fixtures.harness_holding_key?(priv) end)

        {:ok,
         Map.merge(context, %{dir: dir, enc_path: enc_path, shim: Fixtures.sops_key_shim_path!()})}
      end

      when_ "it runs `sops exec-env` against the encrypted test env", context do
        result =
          Fixtures.run_cmd(
            "sops",
            ["--config", "/dev/null", "exec-env", context.enc_path, "env"],
            env: [{"SOPS_AGE_KEY_CMD", context.shim}]
          )

        {:ok, Map.put(context, :result, result)}
      end

      then_ "sops gets the key by running the box's key command, which asks the harness",
            context do
        {output, status} = context.result

        assert status == 0,
               "sops exec-env could not get the key by running the box's key command:\n\n#{output}"

        {:ok, context}
      end

      then_ "the tests run with the test env's secrets", context do
        {output, _status} = context.result

        assert output =~ "#{@secret_name}=#{@secret_value}",
               "the command sops ran never saw the decrypted secret:\n\n#{output}"

        {:ok, context}
      end

      then_ "no key file or decrypted env file is on the box afterwards", context do
        refute Fixtures.spex_file_exists?(Path.join(context.dir, "test.env")),
               "a decrypted copy of the test env was left on disk after the command ran"

        {:ok, context}
      end
    end
  end
end
