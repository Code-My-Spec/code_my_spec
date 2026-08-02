defmodule CodeMySpecSpex.Story967.Criterion7998Spex do
  @moduledoc """
  Story 967 — My secrets live encrypted in my own repo
  Criterion 7998 — The repo alone is not enough to read the secrets.

  Someone holding a full copy of the repo but not Sam's key reads only
  ciphertext. This is what makes committing secrets acceptable at all: the
  repo is not the secret, the key is.

  The scenario reads the committed file directly, which is exactly what a
  person with the repo and no key would have.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Sops`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  @plaintext "prod_database_password_in_the_clear"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :real_working_directory

  spex "The repo alone is not enough to read the secrets" do
    scenario "the encrypted file yields nothing but ciphertext without the key" do
      given_ "the project has an encrypted secret committed", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view
        |> form("[data-test='secret-form']",
          secret: %{key: "DATABASE_URL", value: @plaintext, environment: "prod"}
        )
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "someone with the repo but not the key opens the environment file", context do
        {:ok, contents} = Environments.read_file(context.environment, "envs/prod.enc.env")

        {:ok, Map.put(context, :contents, contents)}
      end

      then_ "they can read nothing but ciphertext", context do
        assert context.contents != "",
               "expected the encrypted file to have content"

        refute context.contents =~ @plaintext,
               "expected the secret value to be unreadable from the repo alone"

        {:ok, context}
      end

      then_ "the key itself is not sitting in the repo beside the ciphertext", context do
        {:ok, entries} = Environments.list_directory(context.environment, ".")

        key_files =
          Enum.filter(entries, fn path ->
            String.contains?(path, "age") and String.ends_with?(path, "key")
          end)

        assert key_files == [],
               "expected no private key committed alongside the secrets it opens, found: #{inspect(key_files)}"

        {:ok, context}
      end
    end
  end
end
