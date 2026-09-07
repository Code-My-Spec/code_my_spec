defmodule CodeMySpecSpex.Story841.Criterion1957Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1957 — Sam pastes tokens once and walks away.

  "Once" is the claim. Every credential the run needs is asked for in one
  sitting, and once they are in, nothing asks again — the run does not stop
  halfway to request a second thing Sam could have given at the start.

  Surface: `ProvisioningLive` on the cloud app. This is the page Sam actually
  types into; the credentials are per-project secrets and per-account
  connections, and only the page collects both in one place.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Sam pastes tokens once and walks away" do
    scenario "one sitting covers every credential, and the blocker clears" do
      given_ "Sam is on the setup page with nothing entered", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        assert html =~ "Still needed:",
               "expected setup to refuse to start while credentials are missing"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he pastes every pasted credential the run needs and saves", context do
        context.view
        |> element("[data-test='manage-credentials']")
        |> render_click()

        html =
          context.view
          |> form("[data-test='credentials-form']",
            credentials: %{
              "hetzner_api_token" => "spex-hetzner-token",
              "hetzner_s3_access_key_id" => "spex-s3-key-id",
              "hetzner_s3_secret_access_key" => "spex-s3-secret"
            }
          )
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "nothing asks him for those again", context do
        for key <- ~w(hetzner_api_token hetzner_s3_access_key_id hetzner_s3_secret_access_key) do
          assert context.html =~ ~s(data-credential="#{key}" ),
                 "expected #{key} to still be listed so its state is visible"

          refute context.html =~ ~s(data-key="#{key}" data-set="false"),
                 "expected #{key} to read as stored after saving, not as still needed"
        end

        {:ok, context}
      end

      then_ "the run's blocker names only what Sam cannot paste", context do
        missing =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='credentials-incomplete']")
          |> Floki.attribute("data-missing")
          |> List.first()

        for key <- ~w(hetzner_api_token hetzner_s3_access_key_id hetzner_s3_secret_access_key) do
          refute missing && String.contains?(missing, key),
                 "expected a pasted credential to stop blocking the run, got missing=#{missing}"
        end

        {:ok, context}
      end
    end
  end
end
