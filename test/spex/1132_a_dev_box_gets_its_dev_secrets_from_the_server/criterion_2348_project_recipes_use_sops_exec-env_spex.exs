defmodule CodeMySpecSpex.Story1132.Criterion2348Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2348 -- Project recipes use sops exec-env.

  Product's decision on this (the question this answers): "Sam's project"
  is a project CodeMySpec *generates*, not this repository. That
  template's own `justfile` is emitted by the `cms_new` generator, which
  lives in its own, separate repository (`config/test.exs`'s own comment:
  "cms_new generates into every project") -- nothing in this working
  copy, or in the sibling `code_my_spec_test_repos` pool of already-
  generated projects, carries its source. Building the real template
  change is therefore out of reach from here; it is reported as such
  rather than claimed.

  What this spec verifies instead is the wrapping pattern itself: a
  fixture project with a `test` recipe shaped exactly the way the
  generated template's is meant to be (`sops exec-env <env> <command>`),
  run for real against a real harness holding the matching key. Proving
  the pattern works is what the template change (wherever it lands) has
  to reproduce; this spec cannot reach forward and confirm it did.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CodeMySpecSpex.Fixtures

  @secret_name "CMS_SPEX_DEV_SECRET"
  @secret_value "value-from-the-dev-env"

  spex "The project's own recipes decrypt their secrets through sops exec-env",
    criterion: 2348 do
    scenario "Sam's project runs `just test`" do
      given_ "Sam's project has a `test` recipe wrapping sops exec-env", context do
        dir = Fixtures.spex_tmp_dir!("generated-project-spex")
        {pub, priv} = Fixtures.age_keypair!(dir)
        Fixtures.sops_encrypt_dotenv!(dir, "test.env", "#{@secret_name}=#{@secret_value}\n", pub)

        Fixtures.spex_write_file!(Path.join(dir, "justfile"), """
        test:
            sops --config /dev/null exec-env test.env env
        """)

        _rig = app_instance_rig(sops_age_keys: [priv])
        eventually(fn -> assert Fixtures.harness_holding_key?(priv) end)

        {:ok, Map.merge(context, %{dir: dir})}
      end

      when_ "`just test` runs", context do
        result =
          Fixtures.run_cmd("just", ["test"],
            cd: context.dir,
            env: [{"SOPS_AGE_KEY_CMD", Fixtures.sops_key_shim_path!()}]
          )

        {:ok, Map.put(context, :result, result)}
      end

      then_ "the recipe runs the tests through sops exec-env and they get their secrets",
            context do
        {output, status} = context.result

        assert status == 0,
               "just test (wrapped in sops exec-env) did not succeed:\n\n#{output}"

        assert output =~ "#{@secret_name}=#{@secret_value}",
               "the command the recipe ran never saw the decrypted secret:\n\n#{output}"

        refute Fixtures.spex_file_exists?(Path.join(context.dir, "test.env.dec")),
               "a decrypted copy of the env was left on disk after the recipe ran"

        {:ok, context}
      end
    end
  end
end
