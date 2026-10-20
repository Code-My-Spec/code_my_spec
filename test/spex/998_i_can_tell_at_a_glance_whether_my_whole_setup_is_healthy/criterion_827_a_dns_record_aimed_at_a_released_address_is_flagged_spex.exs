defmodule CodeMySpecSpex.Story998.Criterion8293Spex do
  @moduledoc """
  Story 998 — I can tell at a glance whether my whole setup is healthy
  Criterion 8293 — A DNS record aimed at a released address is flagged.

  The defect this exists for is already filed (ae37f523): removing an
  environment destroyed the box and left the subdomain resolving to its
  address. Hetzner gives that address to somebody else within the day, so the
  record does not break — it starts pointing at a stranger's machine, which is
  worse than broken and looks like nothing at all.

  No single project can see this. The DNS record and the server are both fine
  in isolation; what is wrong is the relationship between them, and only
  something looking at the whole account can check a relationship.

  A dangling bucket is the cheaper twin: not dangerous, just billing.

  Surface: `CodeMySpecWeb.ResourceLive.Index`, the console's Inventory.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "A DNS record aimed at a released address is flagged", criterion: 827 do
    scenario "a record and a bucket that point at nothing are called out" do
      given_ "setup once provisioned a box at .99 and a bucket for uat", context do
        # Released, not merely unrecognised. A record can only dangle against
        # an address that was *ours* — the first version of this rule flagged
        # anything pointing outside the Hetzner account, which on a real
        # account is every host you run anywhere else.
        context =
          scripted_run(context, %{
            server: fn ->
              {:ok,
               [
                 %{
                   kind: "server",
                   location: "hetzner/uat-box",
                   identifier: "environment=uat ip=203.0.113.99"
                 }
               ]}
            end,
            storage: fn ->
              {:ok,
               [
                 %{
                   kind: "bucket",
                   location: "storage/abandoned-project-uat",
                   identifier: "environment=uat"
                 }
               ]}
            end
          })

        # Retargeted onto the console (provisioning-console-step6, unmerged):
        # see criterion 822's given_ for why running exactly the scripted
        # steps directly has the same effect the whole-run cascade did — no
        # more "wait for a removed step" problem, since nothing is waited on
        # beyond each step's own synchronous run.
        {:ok, server_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers")

        run_console_step(server_view, :server)

        {:ok, storage_view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/storage_backups"
          )

        run_console_step(storage_view, :storage)

        {:ok, context}
      end

      given_ "and that box is gone, its address handed to somebody else", context do
        context =
          stage_inventory(context, %{
            hetzner: [
              inventory_resource(%{
                kind: "server",
                location: "hetzner/live-uat",
                identifier: "203.0.113.10"
              })
            ],
            storage: [
              inventory_resource(%{kind: "bucket", location: "storage/abandoned-project-uat"})
            ],
            cloudflare: [
              inventory_resource(%{
                kind: "dns_record",
                location: "uat.example.com",
                identifier: "A 203.0.113.10"
              }),
              inventory_resource(%{
                kind: "dns_record",
                location: "old.example.com",
                identifier: "A 203.0.113.99"
              }),
              # Never ours. On a real account this is the common case — a
              # marketing site on Fly, an ftp host elsewhere — and flagging it
              # was six of the seven flags the first rule produced.
              inventory_resource(%{
                kind: "dns_record",
                location: "elsewhere.example.com",
                identifier: "A 198.51.100.7"
              })
            ]
          })

        {:ok, context}
      end

      when_ "he opens the resources page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/inventory")

        {:ok, context |> Map.put(:document, Floki.parse_document!(render_async(view, 5_000)))}
      end

      then_ "the record pointing at a released address is marked as pointing at nothing",
            context do
        stale =
          Floki.find(
            context.document,
            "[data-test='resource'][data-location='old.example.com']"
          )

        assert stale != [], "the stale record is not on the page at all"

        assert Floki.attribute(stale, "data-status") == ["dangling"],
               "a record aimed at an address nobody holds reads as fine, which is how " <>
                 "a subdomain ends up resolving to a stranger's machine"

        {:ok, context}
      end

      then_ "and the record that still points at a live server is not", context do
        live_record =
          Floki.find(
            context.document,
            "[data-test='resource'][data-location='uat.example.com']"
          )

        refute Floki.attribute(live_record, "data-status") == ["dangling"],
               "a record pointing at a server that exists was flagged, which trains him " <>
                 "to ignore the flag"

        {:ok, context}
      end

      then_ "and the bucket nothing names is flagged too", context do
        bucket =
          Floki.find(
            context.document,
            "[data-test='resource'][data-location='storage/abandoned-project-uat']"
          )

        assert Floki.attribute(bucket, "data-status") == ["dangling"],
               "a bucket no environment names is listed as though it were in use, and " <>
                 "it bills either way"

        {:ok, context}
      end

      then_ "and a record that was never ours is left alone", context do
        # The regression this rule exists to prevent. Flagging every address
        # outside the provider account is wrong six times out of seven on a
        # real account, and a mark that wrong stops being read at all.
        other =
          Floki.find(
            context.document,
            "[data-test='resource'][data-location='elsewhere.example.com']"
          )

        assert other != [], "the record is not on the page at all"

        refute Floki.attribute(other, "data-status") == ["dangling"],
               "a record pointing at somebody else's host was reported as broken"

        {:ok, context}
      end

      then_ "and it says what the stale record still answers with", context do
        stale =
          Floki.find(
            context.document,
            "[data-test='resource'][data-location='old.example.com']"
          )

        assert Floki.text(stale) =~ "203.0.113.99",
               "he is told a record is stale without being told what it points at, " <>
                 "which is the one thing he needs to go and remove it"

        {:ok, context}
      end
    end
  end
end
