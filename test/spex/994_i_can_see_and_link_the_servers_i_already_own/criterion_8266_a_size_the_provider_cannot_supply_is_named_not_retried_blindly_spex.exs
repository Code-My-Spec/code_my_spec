defmodule CodeMySpecSpex.Story994.Criterion8266Spex do
  @moduledoc """
  Story 994 — I can see and link the servers I already own
  Criterion 8266 — A size the provider cannot supply is named, not retried blindly.

  Not hypothetical. QA of the server step found that no ARM type was available
  in any Hetzner datacenter — cax11 and cax21 both listed, both sold out —
  while the step's default asked for one (issue 92e0b786). Capacity comes and
  goes, so this is a state the screen will meet.

  Two things follow. Sam is told which size, and where it was tried, because
  "provisioning failed" leaves him nothing to change. And nothing is created,
  because a silent fallback to a different size is how you end up paying for a
  machine you did not choose — and, if the architecture differs, one your
  images cannot run on.

  Surface: `CodeMySpecWeb.ServerLive.Index` at `/app/servers`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A size the provider cannot supply is named, not retried blindly" do
    scenario "a sold-out size is reported and nothing is created" do
      given_ "the size Sam asked for is sold out at the provider", context do
        recorder = Fixtures.call_recorder()

        context =
          stage_servers(context, [],
            create: fn _scope, attrs ->
              Fixtures.record_call(recorder, {:create_attempted, attrs})
              {:error, {:capacity_unavailable, "cax21 in fsn1"}}
            end
          )

        {:ok, view, _html} = live(context.conn, "/app/servers")

        {:ok, Map.merge(context, %{view: view, recorder: recorder})}
      end

      when_ "he confirms the provisioning", context do
        context.view
        |> form("[data-test='provision-form']", server: %{size: "cax21", location: "fsn1"})
        |> render_submit()

        html =
          context.view
          |> element("[data-test='provision-confirm']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "he is told that size is unavailable and where it was tried", context do
        error =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provision-error']")

        assert error != [], "a sold-out size produced no error on the page"

        text = Floki.text(error)
        assert text =~ "cax21", "the message does not name the size he asked for"
        assert text =~ "fsn1", "the message does not say where it was tried"

        {:ok, context}
      end

      then_ "and nothing was created, so he is not charged for a box he did not get", context do
        # One attempt, and it failed. A blind retry at another size would show
        # up here as a second message with different attributes.
        assert [{:create_attempted, _attrs}] = Fixtures.recorded_calls(context.recorder)

        rows =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='server']")

        assert rows == [], "a server exists after a provisioning attempt that failed"

        {:ok, context}
      end
    end

    scenario "a size that location does not carry is never on offer" do
      given_ "a size one location supplies and another does not", context do
        # cpx31 exists in Falkenstein and not in Singapore. QA found the form
        # offering every size against every location — 21 options where no
        # location carried more than 16 — so most pairs it permitted could
        # not be built.
        recorder = Fixtures.call_recorder()

        context =
          stage_servers(context, [],
            create: fn _scope, attrs ->
              Fixtures.record_call(recorder, {:create_attempted, attrs})
              {:ok, provider_server(%{name: "should-not-exist"})}
            end
          )

        {:ok, view, html} = live(context.conn, "/app/servers")

        {:ok, Map.merge(context, %{view: view, html: html, recorder: recorder})}
      end

      when_ "he picks the location that does not carry it", context do
        html =
          context.view
          |> form("[data-test='provision-form']", server: %{location: "sin", size: "cpx11"})
          |> render_change()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it is not among the sizes he can choose", context do
        offered =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='size-options'] option")
          |> Enum.map(&(&1 |> Floki.attribute("value") |> List.first()))

        assert "cpx11" in offered, "the size that location does carry is missing"

        refute "cpx31" in offered,
               "a size this location cannot supply was offered as if it could be bought"

        {:ok, context}
      end

      then_ "and asking for it anyway is refused by name rather than quoted blankly", context do
        # Submitted as a raw event rather than through the form, because the
        # form helper now refuses the value outright — which is the narrowing
        # working. The pair still has to be caught server-side: the page can
        # have been open since before the last of that size in Singapore went,
        # and the sold-out race is named in the LiveView's own docs.
        html =
          render_submit(context.view, "stage", %{
            "server" => %{"size" => "cpx31", "location" => "sin"}
          })

        document = Floki.parse_document!(html)
        error = Floki.find(document, "[data-test='provision-error']")

        assert error != [], "an impossible pair was accepted without complaint"

        text = Floki.text(error)
        assert text =~ "cpx31", "the message does not name the size"
        assert text =~ "sin", "the message does not name the location"

        # The cost line rendered "cpx31 in sin — €/hour" with an empty figure
        # and a live confirm button beside it. Consent to an unstated price is
        # not consent.
        assert Floki.find(document, "[data-test='provision-confirm']") == [],
               "he was offered a server to buy with no price attached to it"

        assert Fixtures.recorded_calls(context.recorder) == [],
               "a box was ordered before any price was shown"

        {:ok, context}
      end
    end
  end
end
