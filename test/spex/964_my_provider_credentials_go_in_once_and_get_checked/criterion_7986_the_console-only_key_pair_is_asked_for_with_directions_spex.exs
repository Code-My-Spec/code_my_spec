defmodule CodeMySpecSpex.Story964.Criterion7986Spex do
  @moduledoc """
  Story 964 — My provider credentials go in once and get checked
  Criterion 7986 — The console-only key pair is asked for with directions.

  Hetzner exposes no API for minting object-storage S3 credentials, so
  Sam must create the pair by hand. Intake therefore has to tell him
  where in the Hetzner console to do it, and warn that the secret key
  cannot be read again after creation — a warning that arrives too late
  is a lost credential and a new key pair.

  Surface: `CodeMySpecWeb.CredentialsLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "The console-only key pair is asked for with directions" do
    scenario "the S3 key pair field carries where-to-get-it and a one-look warning" do
      given_ "the object storage option is on", context do
        # Turned on rather than assumed on. The whole criterion is that
        # *this option* is what makes intake ask for the console-only key
        # pair, and taking the option from the defaults would leave the spex
        # passing even if the two came apart.
        view = mount_provisioning(context)
        choose_setup_options(view, [:storage])

        {:ok, context}
      end

      when_ "setup asks Sam for the object storage key pair", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        html =
          view
          |> element("[data-test='manage-credentials']")
          |> render_click()

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "it tells him where in the Hetzner console to create it", context do
        assert has_element?(
                 context.view,
                 "[data-test='credential-field'][data-credential^='hetzner_s3']"
               ),
               "expected intake to ask for the Hetzner S3 key pair"

        directions =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='credential-directions'][data-credential^='hetzner_s3']")
          |> Floki.text()

        assert directions =~ ~r/console/i,
               "expected directions pointing at the Hetzner console, got: #{inspect(directions)}"

        assert directions =~ ~r/security|s3 credentials/i,
               "expected directions naming where in the console the keys live"

        {:ok, Map.put(context, :directions, directions)}
      end

      then_ "it warns the secret key cannot be read again", context do
        assert context.directions =~ ~r/again|once|cannot be (viewed|read)/i,
               "expected a warning that the secret key is unviewable after creation, got: #{inspect(context.directions)}"

        {:ok, context}
      end
    end
  end
end
