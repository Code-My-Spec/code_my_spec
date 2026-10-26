defmodule CodeMySpecSpex.Story973.Criterion968Spex do
  @moduledoc """
  Story 973, criterion 968: the deployed app exposes a protected widget
  dependency check while /health remains a shallow liveness route.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint
  @site "http://127.0.0.1:4100"
  @deploy_key "dk_fleet_spex"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :widget_on_the_fleet

  spex "The widget dependency route is protected and separate from health", criterion: 968 do
    scenario "an authorized check sends a widget message while health stays shallow" do
      given_ "Sam's app has a widget and its deploy key", context do
        probe = "cms-verify-#{System.unique_integer([:positive])}"
        health_before = Req.get!(@site <> "/health", retry: false)
        {:ok, Map.merge(context, %{probe: probe, health_before: health_before})}
      end

      when_ "the dependency route receives the deploy key", context do
        response =
          Req.post!(
            @site <> "/_cms/verify/widget",
            json: %{probe: context.probe},
            headers: [{"authorization", "Bearer " <> @deploy_key}],
            retry: false
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the route reports a real widget check seen by CodeMySpec", context do
        assert context.response.status in 200..299
        assert context.response.body not in [nil, ""]

        {:ok, _inbox, inbox_html} =
          live(context.conn, "/app/projects/#{context.project.id}/inbox")

        assert inbox_html =~ context.probe,
               "expected the operational check to send its probe through the widget integration"

        {:ok, context}
      end

      then_ "health remains a separate shallow liveness probe", context do
        health_after = Req.get!(@site <> "/health", retry: false)
        assert context.health_before.status == 200
        assert health_after.status == 200
        assert context.health_before.body == "ok"
        assert health_after.body == "ok"
        {:ok, context}
      end
    end

    scenario "a request without the deploy key cannot run a dependency check" do
      given_ "a widget check request has no deploy key", context do
        {:ok, Map.put(context, :probe, "cms-verify-#{System.unique_integer([:positive])}")}
      end

      when_ "the dependency route handles the unauthenticated request", context do
        response =
          Req.post!(
            @site <> "/_cms/verify/widget",
            json: %{probe: context.probe},
            retry: false
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it rejects the request without running the widget check", context do
        assert context.response.status == 401

        {:ok, _inbox, inbox_html} =
          live(context.conn, "/app/projects/#{context.project.id}/inbox")

        refute inbox_html =~ context.probe,
               "an unauthenticated request must not generate a widget message"

        {:ok, context}
      end
    end
  end
end
