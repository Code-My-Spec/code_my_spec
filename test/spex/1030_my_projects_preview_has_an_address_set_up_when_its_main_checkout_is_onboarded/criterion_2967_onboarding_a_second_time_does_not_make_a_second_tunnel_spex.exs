defmodule CodeMySpecSpex.Story1030.Criterion2967Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main checkout
  is onboarded.
  Criterion 2967 — Onboarding a second time does not make a second tunnel.

  Rule: The tunnel is created by the server, because the credential that creates
  it is ours and never leaves it.

  Story 891 already requires that running onboarding twice changes nothing, and
  it is run twice constantly — it is the documented way to repair a checkout.
  What makes this criterion its own rather than a restatement is what a second
  tunnel costs.

  Cloudflare returns a tunnel's secret at creation and never again. There is no
  endpoint that re-reads it. So a second create does not merely duplicate work:
  it strands the first tunnel in the account as a real record that nothing holds
  the secret for, that cannot be used, and that nothing will ever report. Run
  onboarding in a loop and you accumulate them silently until somebody opens the
  Cloudflare dashboard months later.

  That is also why idempotence has to key on the *stored credential* rather than
  on asking Cloudflare whether a tunnel of that name exists. "A tunnel with this
  name exists" and "we can still speak for it" are different facts, and only the
  second one is worth anything.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpec.Workspaces.PreviewTunnel

  setup :register_log_in_setup_account
  setup :setup_active_project

  @harness_config ".cms_harness.json"

  spex "Onboarding repeatedly does not litter the account with tunnels" do
    scenario "Onboarding a second time does not make a second tunnel" do
      given_ "a checkout that has already been onboarded once", context do
        :ok = Environments.register(context.project.id, context.environment)

        :ok =
          Environments.write_file(
            context.environment,
            @harness_config,
            Jason.encode!(
              %{working_copy_id: "spex-harness-2967", project_id: context.project.id},
              pretty: true
            )
          )

        stub_cloudflare(self())

        Mix.Task.reenable("cms.harness.onboard")
        Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        {:ok, contents} = Environments.read_file(context.environment, @harness_config)
        first = Jason.decode!(contents)

        # Drain what the first run did, so what the second run does is what the
        # assertions below see.
        flush_cloudflare()

        {:ok, Map.put(context, :first, first)}
      end

      when_ "it is onboarded again", context do
        Mix.Task.reenable("cms.harness.onboard")

        report = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        {:ok, Map.put(context, :report, report)}
      end

      then_ "it is still carrying the tunnel it already had", context do
        {:ok, contents} = Environments.read_file(context.environment, @harness_config)
        second = Jason.decode!(contents)

        assert second["preview_tunnel_id"] == context.first["preview_tunnel_id"],
               "the second run replaced the tunnel. The first one is still in the " <>
                 "account, nothing holds its secret any more — Cloudflare returns it " <>
                 "once, at creation — so it can never be used and nothing will report " <>
                 "it. Onboarding is run repeatedly by design."

        assert second["preview_url"] == context.first["preview_url"],
               "the address moved, so any link already shared for this preview is dead"

        {:ok, context}
      end

      then_ "no second tunnel was asked for", context do
        refute_received {:cloudflare, "/client/v4/accounts/" <> _},
                        "a second tunnel was created"

        {:ok, context}
      end
    end
  end

  defp stub_cloudflare(test_pid) do
    Req.Test.stub(PreviewTunnel, fn conn ->
      send(test_pid, {:cloudflare, conn.request_path})

      if String.contains?(conn.request_path, "cfd_tunnel") do
        Req.Test.json(conn, %{
          "success" => true,
          "result" => %{"id" => "d00dfeed-0000-4000-8000-000000002967"}
        })
      else
        Req.Test.json(conn, %{"success" => true, "result" => %{"id" => "rec-2967"}})
      end
    end)
  end

  defp flush_cloudflare do
    receive do
      {:cloudflare, _} -> flush_cloudflare()
    after
      0 -> :ok
    end
  end
end
