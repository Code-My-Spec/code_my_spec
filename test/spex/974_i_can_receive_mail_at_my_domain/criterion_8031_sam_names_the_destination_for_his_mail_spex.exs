defmodule CodeMySpecSpex.Story974.Criterion8031Spex do
  @moduledoc """
  Story 974 — I can receive mail at my domain
  Criterion 8031 — Sam names the destination for his mail.

  Inbound mail goes where Sam says, not to a mailbox setup invents. He
  already has somewhere he reads mail; a new inbox he has to remember to
  check is a place for messages to be missed.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend` (inbound).
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "resend_inbound_configured_to_named_destination"

  @destination "sam@his-existing-mailbox.example"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam names the destination for his mail" do
    scenario "delivery goes to the mailbox Sam nominated" do
      given_ "Sam already has a mailbox he uses", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "setup configures inbound mail", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> form("[data-test='inbound-form']", inbound: %{destination: @destination})
            |> render_submit()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it delivers to the destination he named", context do
        config =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='inbound-config']")

        # Anchor: an inbound configuration was recorded.
        assert config != [], "expected the inbound configuration to be recorded"

        destination = config |> Floki.attribute("data-destination") |> List.first()

        assert destination == @destination,
               "expected delivery to the mailbox Sam named, got #{inspect(destination)}"

        {:ok, Map.put(context, :config, config)}
      end

      then_ "it does not invent a mailbox he has to check separately", context do
        created = context.config |> Floki.attribute("data-created-new-mailbox") |> List.first()

        assert created == "false",
               "expected no new mailbox to be created for Sam to remember, got #{inspect(created)}"

        {:ok, context}
      end
    end
  end
end
