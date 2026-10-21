defmodule CodeMySpecSpex.Story1132.Criterion2341Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2341 -- The dev key cannot open prod.

  A property of the encryption itself, not of this app's UI: dev and test
  envs are encrypted to a dev-only age recipient, and prod to a different
  one. There is no app surface that picks recipients at encrypt time --
  that already happened when the real `envs/*.enc.env` files were
  committed -- so this drives `sops` and `age-keygen` directly, the same
  real binaries `just init-worktree` and the harness's own decrypt path
  shell out to, through `CodeMySpecSpex.Fixtures`'s `sops_*`/`age_keypair!`
  helpers (the spex boundary's own escape hatch for OS-level programs with
  no app surface). Deterministic local crypto with no network call, so no
  cassette.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  spex "A dev-only key opens dev and test but never prod", criterion: 2341 do
    scenario "Sam's project has dev, test and prod env files" do
      given_ "Sam's project has dev, test and prod env files, each sealed to its own recipient",
             context do
        dir = Fixtures.spex_tmp_dir!("sops-recipients-spex")

        {dev_pub, dev_priv} = Fixtures.age_keypair!(dir)
        {prod_pub, _prod_priv} = Fixtures.age_keypair!(dir)

        dev_enc = Fixtures.sops_encrypt_dotenv!(dir, "dev.enc.env", "SECRET=dev-value\n", dev_pub)

        test_enc =
          Fixtures.sops_encrypt_dotenv!(dir, "test.enc.env", "SECRET=test-value\n", dev_pub)

        prod_enc =
          Fixtures.sops_encrypt_dotenv!(dir, "prod.enc.env", "SECRET=prod-value\n", prod_pub)

        {:ok,
         Map.merge(context, %{
           dev_priv: dev_priv,
           dev_enc: dev_enc,
           test_enc: test_enc,
           prod_enc: prod_enc
         })}
      end

      when_ "the dev-only key is used on each", context do
        env = [{"SOPS_AGE_KEY", context.dev_priv}]

        results = %{
          dev: Fixtures.sops_decrypt_dotenv(context.dev_enc, env: env),
          test: Fixtures.sops_decrypt_dotenv(context.test_enc, env: env),
          prod: Fixtures.sops_decrypt_dotenv(context.prod_enc, env: env)
        }

        {:ok, Map.put(context, :results, results)}
      end

      then_ "it opens dev and test", context do
        assert {:ok, "SECRET=dev-value\n"} = context.results.dev
        assert {:ok, "SECRET=test-value\n"} = context.results.test
        {:ok, context}
      end

      then_ "it cannot open prod", context do
        assert {:error, _reason} = context.results.prod,
               "the dev-only key decrypted the prod env, which must stay on the server only"

        {:ok, context}
      end
    end
  end
end
