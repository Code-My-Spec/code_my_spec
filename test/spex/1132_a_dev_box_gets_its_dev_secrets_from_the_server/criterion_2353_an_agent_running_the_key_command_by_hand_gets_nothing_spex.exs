defmodule CodeMySpecSpex.Story1132.Criterion2353Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2353 -- An agent running the key command by hand gets nothing.

  Runs the real key command directly (`Fixtures.sops_key_shim_path!/0`,
  standing in for the packaged `cms sops-key` -- see that fixture's own
  doc), not through `sops`. Its parent process is then whatever actually
  ran it (this test's own `System.cmd`-spawned shell), never `sops`, so
  the harness's real "only sops may ask for this key" check
  (`CmsHarness.SopsKeySocket.respond/2`) refuses it -- the same check
  criterion 2346/2350 pass through when the caller's parent genuinely is
  `sops`.

  `Fixtures.unique_age_private_key!/0`, not a literal string shaped like
  a key: `CmsHarness.SopsKeyring` is one process shared by the whole spex
  run, and a malformed entry left in it poisons the identity blob for a
  later, real-decrypt scenario elsewhere in the same run (confirmed, not
  theoretical -- see that fixture's own doc).
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CodeMySpecSpex.Fixtures

  spex "The key command refuses a caller that is not sops itself", criterion: 2353 do
    scenario "an agent in 'cloud-1' runs the key command itself, not from sops" do
      given_ "'cloud-1''s harness holds the dev key", context do
        dev_key = Fixtures.unique_age_private_key!()
        _rig = app_instance_rig(sops_age_keys: [dev_key])
        eventually(fn -> assert Fixtures.harness_holding_key?(dev_key) end)
        {:ok, context}
      end

      when_ "an agent runs the key command itself, not from sops", context do
        result = Fixtures.run_cmd(Fixtures.sops_key_shim_path!(), [])
        {:ok, Map.put(context, :result, result)}
      end

      then_ "no key is printed", context do
        {output, _status} = context.result

        refute output =~ "AGE-SECRET-KEY-",
               "running the key command by hand printed a key:\n\n#{output}"

        {:ok, context}
      end

      then_ "it is told the command only answers sops", context do
        {output, _status} = context.result

        assert output =~ "sops",
               "a refusal to a caller that is not sops did not say so:\n\n#{output}"

        {:ok, context}
      end
    end
  end
end
