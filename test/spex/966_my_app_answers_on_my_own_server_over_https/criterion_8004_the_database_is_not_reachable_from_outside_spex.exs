defmodule CodeMySpecSpex.Story966.Criterion8004Spex do
  @moduledoc """
  Story 966 — My app answers on my own server over HTTPS
  Criterion 8004 — The database is not reachable from outside.

  Only the ports the app needs answer from the internet. The database port
  does not. Docker writes its own iptables rules and bypasses UFW, so the
  Hetzner cloud firewall at the network edge is the control that actually
  holds — a spec that only checked the host firewall would pass while
  Postgres sat open to the world.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Deploy`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  # And a modelled shell. Without one the step shells out for real — `ssh` to
  # a TEST-NET address the fake handed back — and the click blocks behind a
  # subprocess that will never answer, which arrives as the whole test timing
  # out three minutes later with a stack in `Phoenix.LiveViewTest.call/2`.
  setup :fake_working_directory

  spex "The database is not reachable from outside" do
    scenario "only the web ports are open at the network edge" do
      given_ "Sam is on the setup status page with credentials entered", context do
        view = mount_provisioning(context)

        # A real Hetzner server is created; register its teardown before it is
        # made so a recording that fails partway still leaves no box running.
        tear_down_after(context.scope, [:server])

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the server step has provisioned the box and its firewall", context do
        paste_provider_credentials(context.view)

        context.view
        |> element("[data-test='setup-step'][data-step='server'] [data-test='run-step']")
        |> render_click()

        # Waited for, then read: the step runs under a supervised task, so
        # `render_click/1` returns while it is still running.
        await_step(context.view, :server)
        html = render(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the ports open from the internet are only the ones the app needs", context do
        rules =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='firewall-rule'][data-direction='in']")

        # Anchor: rules were recorded, so the absence below is meaningful.
        assert rules != [], "expected inbound firewall rules to be recorded"

        public_ports =
          rules
          |> Enum.filter(fn r ->
            (r |> Floki.attribute("data-source") |> List.first()) in ["0.0.0.0/0", "::/0", "any"]
          end)
          |> Enum.map(&(Floki.attribute(&1, "data-port") |> List.first()))
          |> MapSet.new()

        # 22 is open by deliberate decision (key-only SSH — the deploy has to
        # reach the box), so the intended public set is 22/80/443. The
        # criterion's real weight is on 5432: the database never faces the
        # internet, asserted below.
        assert MapSet.subset?(public_ports, MapSet.new(["22", "80", "443"])),
               "expected only ssh and the web ports open to the internet, got #{inspect(MapSet.to_list(public_ports))}"

        {:ok, Map.put(context, :public_ports, public_ports)}
      end

      then_ "the database port does not answer from outside", context do
        refute MapSet.member?(context.public_ports, "5432"),
               "expected the database port never to be open to the internet"

        assert has_element?(
                 context.view,
                 "[data-test='firewall-scope'][data-enforced-at='cloud']"
               ),
               "expected the firewall to be enforced at the Hetzner network edge, since Docker bypasses host firewalls"

        {:ok, context}
      end
    end
  end
end
