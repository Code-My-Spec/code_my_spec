defmodule CodeMySpecSpex.Story967.Criterion7997Spex do
  @moduledoc """
  Story 967 — My secrets live encrypted in my own repo
  Criterion 7997 — A new secret lands in the repo unreadable.

  Setting a secret writes ciphertext into the environment file the repo
  carries. The plaintext appears nowhere in the working tree — not in the
  encrypted file, not in a scratch file left behind, not anywhere a `git
  add` could pick it up.

  The `then_` reads the in-memory project filesystem, which the boundary
  rules sanction here because "no plaintext on disk" *is* the
  user-visible effect.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Sops`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  @plaintext "re_live_plaintext_value_should_never_be_on_disk"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :real_working_directory

  spex "A new secret lands in the repo unreadable" do
    scenario "the value is ciphertext in the file and plaintext nowhere in the tree" do
      given_ "Sam is on the setup status page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he sets an API key for an environment", context do
        context.view
        |> form("[data-test='secret-form']",
          secret: %{key: "RESEND_API_KEY", value: @plaintext, environment: "prod"}
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "the value in the repo's environment file is ciphertext", context do
        {:ok, contents} = Environments.read_file(context.environment, "envs/prod.enc.env")

        # Anchor: the file exists and mentions the key, so the refute below
        # is not passing on an empty or absent file.
        assert contents =~ "RESEND_API_KEY",
               "expected the encrypted environment file to carry the key name"

        refute contents =~ @plaintext,
               "expected the value to be encrypted, found plaintext in envs/prod.enc.env"

        {:ok, context}
      end

      then_ "the plaintext appears nowhere in the working tree", context do
        {:ok, entries} = Environments.list_directory(context.environment, ".")

        offenders =
          Enum.filter(entries, fn path ->
            case Environments.read_file(context.environment, path) do
              {:ok, body} -> String.contains?(body, @plaintext)
              _ -> false
            end
          end)

        assert offenders == [],
               "expected no plaintext anywhere in the tree, found in: #{inspect(offenders)}"

        {:ok, context}
      end
    end
  end
end
