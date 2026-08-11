defmodule CodeMySpecSpex.Story841.Criterion1965Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1965 — Secrets are seeded once and fetched at boot.

  Seeded once: Sam sets a secret one time and every environment that needs it
  gets it. Fetched at boot: the app reads them when it starts rather than
  having them baked into an image, so rotating one does not mean rebuilding.

  Surface: `ProvisioningLive`. The page is where a secret is set and where the
  encrypted files it lands in are named, so both halves are checkable there —
  and the encrypted file is the thing the boot reads.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Secrets are seeded once and fetched at boot" do
    scenario "one secret, every environment, read at start" do
      given_ "Sam is on the setup page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he sets a secret once", context do
        html =
          context.view
          # `key`, which is what the form is named — `name` matched no input at
          # all, so this never submitted anything and failed with "could not
          # find non-disabled input ... with name secret[name]".
          |> form("[data-test='secret-form']", secret: %{key: "API_KEY", value: "spex-secret"})
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it is recorded for the environments that need it", context do
        sources =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='secret-source']")
          |> Floki.text()

        assert sources =~ "uat",
               "expected one seeding to cover the environment, got: #{sources}"

        {:ok, context}
      end

      then_ "the app reads them at boot rather than carrying them in the image", context do
        text = context.html |> Floki.parse_document!() |> Floki.text()

        assert text =~ ".enc.env",
               "expected the secret to land in the encrypted env file the boot decrypts, got: #{text}"

        refute text =~ "baked",
               "a secret baked into an image cannot be rotated without a rebuild"

        {:ok, context}
      end
    end
  end
end
