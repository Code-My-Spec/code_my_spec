defmodule CodeMySpecSpex.Story967.Criterion8049Spex do
  @moduledoc """
  Story 967 — My secrets live encrypted in my own repo
  Criterion 8049 — An agent working in the repo sees only ciphertext.

  This is the one property Varlock had that SOPS has to be made to keep.
  An agent working in the project reads the environment files and its own
  process environment and finds only ciphertext — so no secret value can
  reach a transcript or a log through it.

  The scenario reads what an agent would read: the files in the working
  tree, and the process environment it inherits.

  Surface: filesystem and process environment, as an agent working in the
  project would see them.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  @plaintext "cloudflare_token_agents_must_never_read"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :real_working_directory

  spex "An agent working in the repo sees only ciphertext" do
    scenario "neither the tree nor the process environment yields a secret value" do
      given_ "the project has an encrypted secret", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view
        |> form("[data-test='secret-form']",
          secret: %{key: "CLOUDFLARE_TOKEN", value: @plaintext, environment: "prod"}
        )
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "an agent reads the environment files and its own process environment", context do
        {:ok, entries} = Environments.list_directory(context.environment, ".")

        file_hits =
          Enum.filter(entries, fn path ->
            case Environments.read_file(context.environment, path) do
              {:ok, body} -> String.contains?(body, @plaintext)
              _ -> false
            end
          end)

        env_hits =
          System.get_env()
          |> Enum.filter(fn {_k, v} -> is_binary(v) and String.contains?(v, @plaintext) end)
          |> Enum.map(fn {k, _v} -> k end)

        {:ok, context |> Map.put(:file_hits, file_hits) |> Map.put(:env_hits, env_hits)}
      end

      then_ "it finds only ciphertext in the files", context do
        # Anchor: the encrypted file exists and names the key, so this is a
        # real absence of plaintext rather than an absence of the secret.
        {:ok, contents} = Environments.read_file(context.environment, "envs/prod.enc.env")

        assert contents =~ "CLOUDFLARE_TOKEN",
               "expected the key to be present in the encrypted file"

        assert context.file_hits == [],
               "expected no plaintext in any file an agent can read, found in: #{inspect(context.file_hits)}"

        {:ok, context}
      end

      then_ "no secret value reaches its process environment", context do
        assert context.env_hits == [],
               "expected no decrypted secret in the process environment, found under: #{inspect(context.env_hits)}"

        {:ok, context}
      end
    end
  end
end
