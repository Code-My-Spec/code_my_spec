defmodule CodeMySpecSpex.Story974.Criterion2088Spex do
  @moduledoc """
  Story 974, criterion 655: Sam names the address his mail reaches him at.

  Surface: the cloud mail setup console. The inbound step pauses for Sam's
  address, and its delivery proof must name the address he supplied.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint
  @domain "astralbi.com"
  @destination "sam@astralbi.com"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "Sam names the address his mail reaches him at", criterion: 655 do
    scenario "inbound setup delivers to the address Sam supplies" do
      given_ "Sam is setting up inbound mail for his domain", context do
        own_domain(context.project, @domain)
        zone_exists(context, @domain)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/mail")

        run_console_step(view, :email)
        run_console_step(view, :inbound)

        html = render(view)

        assert html =~ ~r/data-step="inbound"[^>]*data-state="paused"/,
               "expected setup to wait for Sam's destination address"

        assert has_element?(view, "[data-test='inbound-probe-address']"),
               "expected Sam to be asked for an address"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he tells setup which address he actually reads", context do
        resolve_console_pause(context.view, :inbound, @destination)
        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "mail sent to his domain is delivered there", context do
        proof =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='inbound-delivery-proof']")

        assert proof != [], "expected a delivered message, not only published records"
        assert proof |> Floki.attribute("data-state") |> List.first() == "delivered"
        assert proof |> Floki.attribute("data-target") |> List.first() == @destination

        {:ok, Map.put(context, :proof, proof)}
      end

      then_ "setup did not choose a destination on his behalf", context do
        assert context.html =~ ~r/data-step="inbound"[^>]*data-state="done"/,
               "expected inbound setup to finish only after Sam named the destination"

        assert context.proof |> Floki.attribute("data-target") |> List.first() == @destination
        {:ok, context}
      end
    end
  end
end
