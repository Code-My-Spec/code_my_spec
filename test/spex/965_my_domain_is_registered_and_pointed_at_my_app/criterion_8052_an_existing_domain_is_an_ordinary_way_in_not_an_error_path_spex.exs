defmodule CodeMySpecSpex.Story965.Criterion8052Spex do
  @moduledoc """
  Story 965 — My domain is registered and pointed at my app
  Criterion 8052 — An existing domain is an ordinary way in, not an error path.

  Most projects already own their domain. Bringing one is a first-class
  path, not the fallback that happens when buying fails: setup adopts the
  domain Sam names, creates his records, and never offers to sell him
  anything. Treating it as an error path would make the common case feel
  like a failure.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Cloudflare`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "cloudflare_zone_already_in_account"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An existing domain is an ordinary way in, not an error path" do
    scenario "a domain Sam already owns is adopted without any purchase offer" do
      given_ "Sam already owns his domain", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the domain step runs", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> form("[data-test='domain-form']", domain: %{name: "already-mine.com"})
            |> render_submit()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it adopts the domain he named and creates his records", context do
        assert context.html =~ ~r/data-step="domain"[^>]*data-state="done"/,
               "expected the existing domain to be adopted as an ordinary success"

        assert has_element?(
                 context.view,
                 "[data-test='domain-registered'][data-adopted='true']"
               ),
               "expected the domain to be recorded as adopted rather than bought"

        {:ok, context}
      end

      then_ "it never offers to buy anything", context do
        refute has_element?(context.view, "[data-test='confirm-purchase']"),
               "expected no purchase confirmation for a domain Sam already owns"

        refute has_element?(context.view, "[data-test='domain-price']"),
               "expected no price to be quoted for a domain Sam already owns"

        {:ok, context}
      end

      then_ "it is not presented as a failure", context do
        refute context.html =~ ~r/data-step="domain"[^>]*data-state="errored"/,
               "expected bringing your own domain not to read as an error"

        refute context.html =~ ~r/data-step="domain"[^>]*data-state="paused"/,
               "expected no dashboard errand for a domain that is already in the account"

        {:ok, context}
      end
    end
  end
end
