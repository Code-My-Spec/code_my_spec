defmodule CodeMySpecSpex.Story1132.Criterion2353Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2353 -- An agent running the key command by hand gets nothing.

  Runs the key command directly (`System.cmd/3`), not through `sops`, the
  way an agent that reads `SOPS_AGE_KEY_CMD` out of its own environment
  and tries it by hand would. The command the story's notes describe
  (`cms sops-key`) does not exist in this codebase yet.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CodeMySpecSpex.Fixtures

  spex "The key command refuses a caller that is not sops itself", criterion: 2353 do
    scenario "an agent in 'cloud-1' runs the key command itself, not from sops" do
      given_ "'cloud-1''s harness holds the dev key", context do
        rig = app_instance_rig(sops_age_keys: ["AGE-SECRET-KEY-1DEV"])
        Process.sleep(300)
        {:ok, Map.put(context, :rig, rig)}
      end

      when_ "an agent runs the key command itself, not from sops", context do
        result = Fixtures.run_cmd("cms", ["sops-key"])
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
