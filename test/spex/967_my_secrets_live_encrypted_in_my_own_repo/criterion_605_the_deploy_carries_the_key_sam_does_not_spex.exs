defmodule CodeMySpecSpex.Story967.Criterion7999Spex do
  @moduledoc """
  Story 967 — My secrets live encrypted in my own repo
  Criterion 7999 — The deploy carries the key, Sam does not.

  The age private key reaches the server through the deploy tool rather
  than a file Sam SSHes in to place. He never logs into the box to set up
  decryption — which is what keeps the server reproducible and keeps the
  key out of a shell history.

  Retargeted onto the console (provisioning-console-step6, unmerged): the
  secret is set on `/console/secrets` (see criterion 603's moduledoc), and
  deploy is its own page now, not a row on the same long page — each
  environment is a `[data-test='deploy-row']` on `/console/deploys`, same
  as criterion 613's moduledoc describes for other steps moving onto
  per-resource pages.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Sops`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_working_directory
  setup :fake_providers
  setup :repo_secret_setup

  spex "The deploy carries the key, Sam does not", criterion: 605 do
    scenario "the key travels as deploy configuration, not as a file placed by hand" do
      given_ "the project has encrypted secrets for an environment", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/secrets")

        open_secrets_dialog(view)

        view
        |> form("[data-test='secret-form']",
          secret: %{key: "SECRET_KEY_BASE", value: "generated-value", environment: "uat"}
        )
        |> render_submit()

        {:ok, deploys_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/deploys?env=uat")

        {:ok, Map.put(context, :view, deploys_view)}
      end

      when_ "Sam deploys that environment", context do
        html =
          context.view
          |> form(
            "[data-test='deploy-row'][data-step='deploy'][data-environment='uat'] [data-test='deploy-environment-form']",
            %{"environment" => "uat"}
          )
          |> render_submit()

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
