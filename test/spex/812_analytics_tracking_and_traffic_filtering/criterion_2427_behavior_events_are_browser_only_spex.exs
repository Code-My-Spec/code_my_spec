defmodule CodeMySpecSpex.Story812.Criterion2427Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 2427 — browser behavior events stay in the browser; server
  Measurement Protocol delivery is reserved for conversions and lifecycle.

  Drive the public pages and registration form. The GA subscriber observes
  what the server actually sends without calling the Analytics context.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  @server_events ~w(sign_up registration_email_sent first_cli_connect)

  setup do
    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)
    :ok
  end

  spex "Behavior events are browser-only and server MP carries only conversions and lifecycle events",
    criterion: 2427 do
    scenario "loading an install page leaves page_view and install copy tracking to the browser" do
      given_ "an unauthenticated visitor with no conversion in progress", context do
        # given: already true — CodeMySpecSpex.Case supplies a fresh, unauthenticated conn.
        {:ok, context}
      end

      when_ "the visitor loads the install page", context do
        html = html_response(get(context.conn, "/install"), 200)
        {:ok, Map.put(context, :html, html)}
      end

      then_ "the page equips the browser to track page and install behavior", context do
        assert context.html =~ "googletagmanager.com/gtag/js"
        assert context.html =~ ~s(data-event-name="install_command_copy")
        {:ok, context}
      end

      then_ "loading the page sends no server Measurement Protocol behavior event", context do
        refute_receive {:ga_measurement_protocol, _payload}, 100
        {:ok, context}
      end
    end

    scenario "the removed server behavior-event route cannot accept a browser event" do
      given_ "a visitor who could send a browser behavior event", context do
        # given: already true — CodeMySpecSpex.Case supplies a conn able to POST to the web endpoint.
        {:ok, context}
      end

      when_ "the visitor posts page_view to the old analytics route", context do
        conn = post(context.conn, "/api/browser/analytics/event", %{event: "page_view"})
        {:ok, Map.put(context, :response, conn)}
      end

      then_ "the server has no behavior-event route", context do
        assert context.response.status == 404
        refute_receive {:ga_measurement_protocol, _payload}, 100
        {:ok, context}
      end
    end

    scenario "a real signup sends a conversion rather than a page or behavior event" do
      given_ "a first-time visitor with a fresh email", context do
        email = "spex-812-browser-only-#{System.unique_integer([:positive])}@codemyspec.test"
        {:ok, Map.put(context, :email, email)}
      end

      when_ "the visitor submits the magic-link registration form", context do
        {:ok, view, _html} = live(context.conn, "/users/register")
        view |> form("#registration_form", user: %{email: context.email}) |> render_submit()
        {:ok, context}
      end

      then_ "server MP carries the signup conversion and no browser behavior event", context do
        assert_receive {:ga_measurement_protocol, %{events: events}}, 1_000
        names = Enum.map(events, & &1.name)
        assert "sign_up" in names
        assert Enum.all?(names, &(&1 in @server_events))
        {:ok, context}
      end
    end
  end
end
