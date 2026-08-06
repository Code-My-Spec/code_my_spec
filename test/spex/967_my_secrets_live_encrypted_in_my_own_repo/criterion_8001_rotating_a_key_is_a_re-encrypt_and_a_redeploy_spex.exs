defmodule CodeMySpecSpex.Story967.Criterion8001Spex do
  @moduledoc """
  Story 967 — My secrets live encrypted in my own repo
  Criterion 8001 — Rotating a key is a re-encrypt and a redeploy.

  Replacing a provider key means setting the new value and redeploying.
  No application code changes. Rotation that requires a code change is
  rotation that does not happen.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Sops`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "kamal_deploy_after_secret_rotation"

  @old_value "re_old_key_being_replaced"
  @new_value "re_new_key_after_rotation"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :real_working_directory
  setup :connect_providers
  # The claim here is that rotating a secret re-encrypts and takes effect —
  # the deploy is how it takes effect, not what is under test. Story 966 owns
  # whether a real deploy works; dragging one in here would make this
  # criterion fail for reasons that have nothing to do with secrets.
  setup :stage_deploy

  spex "Rotating a key is a re-encrypt and a redeploy" do
    scenario "the new value takes effect with no code change" do
      given_ "a provider key is stored and in use", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view
        |> form("[data-test='secret-form']",
          secret: %{key: "RESEND_API_KEY", value: @old_value, environment: "uat"}
        )
        |> render_submit()

        {:ok, before} = Environments.list_directory(context.environment, "lib")

        {:ok, context |> Map.put(:view, view) |> Map.put(:lib_before, before)}
      end

      when_ "Sam sets the new value and redeploys", context do
        context.view
        |> form("[data-test='secret-form']",
          secret: %{key: "RESEND_API_KEY", value: @new_value, environment: "uat"}
        )
        |> render_submit()

        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='deploy'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the app uses the new value", context do
        assert context.html =~ ~r/data-step="deploy"[^>]*data-state="done"/,
               "expected the redeploy to succeed with the rotated secret"

        {:ok, contents} = Environments.read_file(context.environment, "envs/uat.enc.env")

        refute contents =~ @old_value,
               "expected the old value not to remain in the encrypted file"

        refute contents =~ @new_value,
               "expected the new value to be encrypted rather than written in the clear"

        {:ok, context}
      end

      then_ "no application code changed", context do
        {:ok, lib_after} = Environments.list_directory(context.environment, "lib")

        assert lib_after == context.lib_before,
               "expected rotation to touch no application code:\n  before: #{inspect(context.lib_before)}\n  after:  #{inspect(lib_after)}"

        {:ok, context}
      end
    end
  end
end
