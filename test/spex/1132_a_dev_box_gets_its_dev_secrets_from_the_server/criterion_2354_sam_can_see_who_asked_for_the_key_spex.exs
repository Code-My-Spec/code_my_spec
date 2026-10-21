defmodule CodeMySpecSpex.Story1132.Criterion2354Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2354 -- Sam can see who asked for the key.

  Drives a sops-mediated request (same shape as criterion 2346) and a
  hand-run refusal (same shape as criterion 2353), then reads the
  harness's own log the way Sam would -- `~/.codemyspec/harness.out`, the
  path the cloud setup script already redirects the harness's output to
  (`priv/dev_boxes/claude_code_cloud_setup.sh`). There is no release-of-key
  logging in this codebase yet (`CmsHarness.SopsKeyring.install/2` logs
  only that a count of keys was added to a file, never a caller or a
  refusal), so this is expected to find neither request recorded.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CodeMySpecSpex.Fixtures

  @log_path Path.expand("~/.codemyspec/harness.out")

  spex "Every key request, granted or refused, is in the harness's own log", criterion: 2354 do
    scenario "sops asked for the key and an agent's hand-run key command was refused" do
      given_ "'cloud-1''s harness holds the dev key", context do
        rig = app_instance_rig(sops_age_keys: ["AGE-SECRET-KEY-1DEV"])
        Process.sleep(300)
        {:ok, Map.put(context, :rig, rig)}
      end

      when_ "sops asks for the key, and an agent's hand-run key command is refused", context do
        dir = Fixtures.spex_tmp_dir!("sops-log-spex")
        {pub, _priv} = Fixtures.age_keypair!(dir)
        enc_path = Fixtures.sops_encrypt_dotenv!(dir, "test.enc.env", "SECRET=whatever\n", pub)

        Fixtures.sops_decrypt_dotenv(enc_path, env: [{"SOPS_AGE_KEY_CMD", "cms sops-key"}])
        Fixtures.run_cmd("cms", ["sops-key"])

        {:ok, context}
      end

      then_ "Sam reads the harness log", context do
        {:ok, Map.put(context, :log, Fixtures.spex_read_file_or_blank(@log_path))}
      end

      then_ "both requests are there with the process that made each, and the refusal is marked",
            context do
        assert context.log =~ "sops",
               "the harness's log does not record sops's own request for the key:\n\n#{context.log}"

        assert context.log =~ "refused",
               "the harness's log does not mark the hand-run request as refused:\n\n#{context.log}"

        {:ok, context}
      end
    end
  end
end
