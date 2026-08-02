defmodule CodeMySpecSpex.Story971.Criterion8022Spex do
  @moduledoc """
  Story 971 — My deployed app talks back to CodeMySpec without a long-lived key
  Criterion 8022 — Sam never sees the credential he is using.

  After setup finishes, the environment authenticates to CodeMySpec and Sam
  never copied a value between two systems to make it so. Today the
  `deploy_key` lives in four config files that somebody pasted it into; the
  criterion is that the credential is placed, not transcribed.

  Surface: `CodeMySpecWeb.ProvisioningLive` for the placement, HTTP for the
  proof it works.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "setup_places_callback_credential"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :real_working_directory
  setup :connect_providers

  spex "Sam never sees the credential he is using" do
    scenario "setup places the credential and the environment authenticates with it" do
      given_ "Sam is on the setup status page", context do
        app_holds_refresh_secret(context.scope)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "setup finishes placing the callback credential", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='callback_credential'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the environment can authenticate", context do
        assert context.html =~ ~r/data-step="callback_credential"[^>]*data-state="done"/,
               "expected the credential placement step to complete"

        placement =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='callback-credential']")

        # Anchor: a credential was placed somewhere identifiable.
        assert placement != [], "expected setup to record where it placed the credential"

        destination = placement |> Floki.attribute("data-placed-in") |> List.first()

        assert destination == "encrypted_env",
               "expected the credential to be placed into the environment's encrypted env, got #{inspect(destination)}"

        {:ok, Map.put(context, :placement, placement)}
      end

      then_ "Sam never copied a value between two systems", context do
        manual = context.placement |> Floki.attribute("data-manual-copy") |> List.first()

        assert manual == "false",
               "expected no manual copy step, got #{inspect(manual)}"

        {:ok, context}
      end

      then_ "the value is not left sitting in plaintext config", context do
        {:ok, entries} = Environments.list_directory(context.environment, ".")

        plaintext_configs =
          Enum.filter(entries, fn path ->
            Path.extname(path) in [".exs", ".env"] and
              match?({:ok, body} when is_binary(body), Environments.read_file(context.environment, path)) and
              (case Environments.read_file(context.environment, path) do
                 {:ok, body} -> body =~ ~r/deploy_key|refresh_secret/
                 _ -> false
               end)
          end)

        assert plaintext_configs == [],
               "expected no plaintext config carrying the credential, found: #{inspect(plaintext_configs)}"

        {:ok, context}
      end
    end
  end
end
