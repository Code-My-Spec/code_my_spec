defmodule CodeMySpecSpex.Story966.Criterion8010Spex do
  @moduledoc """
  Story 966 — My app answers on my own server over HTTPS
  Criterion 8010 — Sam finds out when his site stops answering.

  Every public hostname gets an uptime monitor, installed before the
  environment is called done. A solo founder cannot watch his own site;
  the monitor is the thing that tells him it went down rather than a
  customer doing it.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Deploy`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "uptime_monitor_created_per_host"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam finds out when his site stops answering" do
    scenario "every public hostname has a monitor before the environment is done" do
      given_ "Sam is on the setup status page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "setup finishes an environment", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='monitoring'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "each public hostname has a monitor watching it", context do
        parsed = Floki.parse_document!(context.html)

        hosts =
          parsed
          |> Floki.find("[data-test='environment-verification']")
          |> Enum.map(&(Floki.attribute(&1, "data-host") |> List.first()))
          |> Enum.reject(&is_nil/1)

        monitored =
          parsed
          |> Floki.find("[data-test='uptime-monitor']")
          |> Enum.map(&(Floki.attribute(&1, "data-host") |> List.first()))
          |> MapSet.new()

        # Anchor: monitors were recorded at all.
        assert MapSet.size(monitored) > 0, "expected setup to record the monitors it installed"

        for host <- hosts do
          assert MapSet.member?(monitored, host),
                 "expected a monitor for #{host}, monitored: #{inspect(MapSet.to_list(monitored))}"
        end

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "the monitor would tell him if the site stopped answering", context do
        notify =
          context.parsed
          |> Floki.find("[data-test='uptime-monitor']")
          |> Floki.attribute("data-notifies")
          |> List.first()

        assert is_binary(notify) and notify != "",
               "expected the monitor to record where it sends notice, otherwise it watches silently"

        {:ok, context}
      end

      then_ "the environment is only called done with its monitor in place", context do
        assert context.html =~ ~r/data-step="monitoring"[^>]*data-state="done"/,
               "expected monitoring to be part of the environment being done, not an afterthought"

        {:ok, context}
      end
    end
  end
end
