defmodule CodeMySpecSpex.Story973.Criterion967Spex do
  @moduledoc """
  Story 973, criterion 967: setup asks the deployed app to send a real widget
  message and observes its arrival before reporting the widget step done.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :widget_on_the_fleet

  spex "Setup proves the widget through the deployed app", criterion: 967 do
    scenario "an operational probe crosses the widget socket before setup completes" do
      given_ "the widget is configured on Sam's deployed app", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/widget?env=prod"
          )

        {:ok, Map.put(context, :view, view)}
      end

      when_ "setup verifies the widget through the app's operational endpoint", context do
        run_console_step(context.view, :widget)
        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "CodeMySpec has received the app's probe message", context do
        {:ok, _inbox, inbox_html} =
          live(context.conn, "/app/projects/#{context.project.id}/inbox")

        assert inbox_html =~ "cms-verify-",
               "expected the deployed app's operational widget probe in Sam's inbox"

        {:ok, context}
      end

      then_ "setup records the received message before marking the widget done", context do
        parsed = Floki.parse_document!(context.html)
        proof = Floki.find(parsed, "[data-test='widget-message-proof']")
        step = Floki.find(parsed, "[data-test='resource-step'][data-step='widget']")

        assert proof != [], "expected a CodeMySpec-side message proof"
        assert Floki.attribute(proof, "data-state") == ["received"]
        assert Floki.attribute(proof, "data-origin") == ["deployed_site"]
        assert Floki.attribute(step, "data-state") == ["done"]

        [proven_at] = Floki.attribute(proof, "data-completed-at")
        [done_at] = Floki.attribute(step, "data-completed-at")
        assert proven_at <= done_at

        {:ok, context}
      end
    end
  end
end
