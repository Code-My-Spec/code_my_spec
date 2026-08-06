defmodule CodeMySpecSpex.Story998.Criterion8297Spex do
  @moduledoc """
  Story 998 — I can tell at a glance whether my whole setup is healthy
  Criterion 8297 — One broken thing shows at the top without reading the list.

  The page has two readers and only one of them knows what any of this is.

  For the other, a list of forty resources is not an answer to "are we okay" —
  it is a research task, and the honest thing is to do the arithmetic for them.
  One number, before any of the detail, that says whether today is a bad day.

  The counterpart matters as much: exactly one thing red when exactly one thing
  is wrong. A page that colours half the list amber to look thorough teaches
  the reader that red means nothing, and then the page has cost them the one
  signal it existed to give.

  Surface: `CodeMySpecWeb.ResourceLive.Index` at `/app/resources`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "One broken thing shows at the top without reading the list" do
    scenario "everything in place except one record" do
      given_ "everything the account should have, except one DNS record pointing at nothing",
             context do
        context =
          stage_inventory(context, %{
            hetzner: [
              inventory_resource(%{
                kind: "server",
                location: "hetzner/uat-box",
                identifier: "203.0.113.10"
              }),
              inventory_resource(%{kind: "ssh_key", location: "hetzner/codemyspec"}),
              inventory_resource(%{kind: "firewall", location: "hetzner/web"}),
              inventory_resource(%{kind: "bucket", location: "project-uat"})
            ],
            cloudflare: [
              inventory_resource(%{
                kind: "dns_record",
                location: "uat.example.com",
                identifier: "A 203.0.113.10"
              }),
              inventory_resource(%{
                kind: "dns_record",
                location: "gone.example.com",
                identifier: "A 203.0.113.99"
              })
            ],
            resend: [
              inventory_resource(%{kind: "sending_domain", location: "resend/example.com"})
            ]
          })

        {:ok, context}
      end

      when_ "someone who does not know what a DNS record is opens the page", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/resources")

        {:ok, context |> Map.put(:document, Floki.parse_document!(render_async(view)))}
      end

      then_ "the page reports the account unhealthy before any resource is read", context do
        summary = Floki.find(context.document, "[data-test='health-summary']")

        assert summary != [],
               "there is nothing to read but the list itself, so the answer to 'are we " <>
                 "okay' is a research task"

        assert Floki.attribute(summary, "data-status") == ["unhealthy"]

        {:ok, Map.put(context, :summary, summary)}
      end

      then_ "and it says how many things are wrong", context do
        assert Floki.attribute(context.summary, "data-problems") == ["1"],
               "the count is the whole point — one is a bad afternoon and twenty is a " <>
                 "bad week, and they need different reactions"

        assert Floki.text(context.summary) =~ "1"

        {:ok, context}
      end

      then_ "and the one thing that is wrong is the only thing marked red", context do
        flagged =
          context.document
          |> Floki.find("[data-test='resource'][data-status='dangling']")
          |> Floki.attribute("data-location")

        assert flagged == ["gone.example.com"],
               "expected exactly the stale record to be flagged; got #{inspect(flagged)} — " <>
                 "colouring more than is wrong teaches him that red means nothing"

        {:ok, context}
      end
    end
  end
end
