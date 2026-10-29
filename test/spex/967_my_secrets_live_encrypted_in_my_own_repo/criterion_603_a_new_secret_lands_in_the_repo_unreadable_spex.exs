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

  Retargeted onto the console (provisioning-console-step6, unmerged): the
  secrets form lives on its own plain page now, always visible like
  `/console/credentials` — see criterion 613's moduledoc for that move.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Sops`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts

  @endpoint CodeMySpecWeb.Endpoint

  @plaintext "re_live_plaintext_value_should_never_be_on_disk"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :real_working_directory
  setup :fake_providers
  setup :repo_secret_setup

  spex "A new secret lands in the repo unreadable", criterion: 603 do
    scenario "the value is ciphertext in the file and plaintext nowhere in the tree" do
      given_ "Sam is on the setup status page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/secrets")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he sets an API key for an environment", context do
        open_secrets_dialog(context.view)

        context.view
        |> form("[data-test='secret-form']",
          secret: %{key: "RESEND_API_KEY", value: @plaintext, environment: "prod"}
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "the value in the repo's environment file is ciphertext", context do
        {:ok, contents} =
          repo_secret_file(context, "envs/prod.enc.env")

        # Anchor: the file exists and mentions the key, so the refute below
        # is not passing on an empty or absent file.
        assert contents =~ "RESEND_API_KEY",
               "expected the encrypted environment file to carry the key name"

        refute contents =~ @plaintext,
               "expected the value to be encrypted, found plaintext in envs/prod.enc.env"

        assert [%{path: "envs/prod.enc.env", content: ^contents, branch: "main"}] =
                 repo_secret_commits(context)

        {:ok, context}
      end

      then_ "the plaintext appears nowhere in the working tree", context do
        {:ok, entries} = ExecutionContexts.list_directory(context.execution_context, ".")

        offenders =
          Enum.filter(entries, &contains_plaintext?(context.execution_context, &1))

        assert offenders == [],
               "expected no plaintext anywhere in the tree, found in: #{inspect(offenders)}"

        {:ok, context}
      end
    end
  end

  defp contains_plaintext?(environment, path) do
    environment
    |> ExecutionContexts.read_file(path)
    |> body_contains_plaintext?()
  end

  defp body_contains_plaintext?({:ok, body}), do: String.contains?(body, @plaintext)
  defp body_contains_plaintext?(_error), do: false
end
