defmodule CodeMySpecSpex.Story967.Criterion7999Spex do
  @moduledoc """
  Story 967 — My secrets live encrypted in my own repo
  Criterion 7999 — The deploy carries the key, Sam does not.

  The age private key reaches the server through the deploy tool rather
  than a file Sam SSHes in to place. He never logs into the box to set up
  decryption — which is what keeps the server reproducible and keeps the
  key out of a shell history.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Sops`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_working_directory
  setup :fake_providers

  spex "The deploy carries the key, Sam does not" do
    scenario "the key travels as deploy configuration, not as a file placed by hand" do
      given_ "the project has encrypted secrets for an environment", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view
        |> form("[data-test='secret-form']",
          secret: %{key: "SECRET_KEY_BASE", value: "generated-value", environment: "uat"}
        )
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam deploys that environment", context do
        html =
          context.view
          |> element("[data-test='setup-step'][data-step='deploy'] [data-test='run-step']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the app decrypts its secrets using the key the deploy supplied", context do
        parsed = Floki.parse_document!(context.html)

        key_delivery =
          parsed
          |> Floki.find("[data-test='age-key-delivery']")

        # Anchor: the deploy recorded how the key got there.
        assert key_delivery != [],
               "expected the deploy to record how the decryption key was supplied"

        via = key_delivery |> Floki.attribute("data-via") |> List.first()

        assert via == "deploy_env",
               "expected the key to arrive as deploy-supplied environment, got #{inspect(via)}"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "Sam never logged in to place a key file himself", context do
        manual =
          context.parsed
          |> Floki.find("[data-test='age-key-delivery']")
          |> Floki.attribute("data-manual-step-required")
          |> List.first()

        assert manual == "false",
               "expected no manual key placement on the host, got #{inspect(manual)}"

        refute context.html =~ ~r/keys\.txt/,
               "expected the key not to be delivered as a host file path"

        {:ok, context}
      end
    end
  end
end
