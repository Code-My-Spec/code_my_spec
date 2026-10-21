defmodule CodeMySpecSpex.Story1132.Criterion2354Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2354 -- Sam can see who asked for the key.

  Drives a sops-mediated request (same shape as criterion 2346) and a
  hand-run refusal (same shape as criterion 2353), capturing the
  harness's own `Logger` output around both
  (`CmsHarness.SopsKeySocket.respond/2` logs every release and refusal) --
  the socket connection is a separate OS process, but the harness side of
  it runs in this same node, so its own log output is this test's own
  `Logger`, the same way any other in-process component's is. Reading a
  log *file* is production-only plumbing (`install_harness_file_logger/0`
  runs from `CmsHarness.Application.start_harness/0`, never reached when
  a spex boots the harness tree directly), not something to fake here.

  A release logs at `:info`, below this suite's default `:logger` level
  (`:warning`, `config/test.exs`). That default is a *primary* filter --
  it drops the event before any handler (including `capture_log`'s own)
  ever sees it, and `capture_log/2`'s own `:level` option only raises the
  calling *process*, not the connection handler process that actually
  logs the release. Raising the level globally with `Logger.configure/1`
  is what reaches it; `async: false` is what makes that safe to do, since
  no other test is running while this one does.

  `Fixtures.unique_age_private_key!/0`, not a literal string shaped like
  a key: `CmsHarness.SopsKeyring` is one process shared by the whole spex
  run, and a malformed entry left in it poisons the identity blob for a
  later, real-decrypt scenario elsewhere in the same run (confirmed, not
  theoretical -- see that fixture's own doc).
  """

  use CodeMySpecSpex.Case, async: false

  require Logger

  import CmsHarnessTest.AppInstanceHelpers
  import ExUnit.CaptureLog

  alias CodeMySpecSpex.Fixtures

  spex "Every key request, granted or refused, is in the harness's own log", criterion: 2354 do
    scenario "sops asked for the key and an agent's hand-run key command was refused" do
      given_ "'cloud-1''s harness holds the dev key", context do
        dev_key = Fixtures.unique_age_private_key!()
        _rig = app_instance_rig(sops_age_keys: [dev_key])
        eventually(fn -> assert Fixtures.harness_holding_key?(dev_key) end)
        {:ok, context}
      end

      when_ "sops asks for the key, and an agent's hand-run key command is refused", context do
        shim = Fixtures.sops_key_shim_path!()

        previous_level = Logger.level()
        Logger.configure(level: :info)
        on_exit(fn -> Logger.configure(level: previous_level) end)

        log =
          capture_log(fn ->
            dir = Fixtures.spex_tmp_dir!("sops-log-spex")
            {pub, _priv} = Fixtures.age_keypair!(dir)

            enc_path =
              Fixtures.sops_encrypt_dotenv!(dir, "test.enc.env", "SECRET=whatever\n", pub)

            Fixtures.sops_decrypt_dotenv(enc_path, env: [{"SOPS_AGE_KEY_CMD", shim}])
            Fixtures.run_cmd(shim, [])
          end)

        {:ok, Map.put(context, :log, log)}
      end

      then_ "both requests are there with the process that made each, and the refusal is marked",
            context do
        assert context.log =~ ~r/released the sops key to pid \d+/,
               "the harness's log does not record a request granted, naming the pid:\n\n#{context.log}"

        assert context.log =~ ~r/refused a sops key request from pid \d+/,
               "the harness's log does not record the hand-run request as refused, naming the " <>
                 "pid:\n\n#{context.log}"

        {:ok, context}
      end
    end
  end
end
