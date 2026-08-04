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

  Surface: `CodeMySpecWeb.ServersLive` at `/app/servers`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A size the provider cannot supply is named, not retried blindly" do
    scenario "a sold-out size is reported and nothing is created" do
      given_ "the size Sam asked for is sold out at the provider", context do
        owner = self()

        context =
          stage_servers(context, [],
            create: fn _scope, attrs ->
              send(owner, {:create_attempted, attrs})
              {:error, {:capacity_unavailable, "cax21 in fsn1"}}
            end
          )

        {:ok, view, _html} = live(context.conn, ~p"/app/servers")

        {:ok, Map.put(context, :view, view)}
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
        assert_received {:create_attempted, _attrs}
        refute_received {:create_attempted, _other}

        rows =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='server']")

        assert rows == [], "a server exists after a provisioning attempt that failed"

        {:ok, context}
      end
    end
  end
end
