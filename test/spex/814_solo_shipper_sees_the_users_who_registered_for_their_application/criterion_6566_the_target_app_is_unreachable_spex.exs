defmodule CodeMySpecSpex.Story814.Criterion6566Spex do
  @moduledoc """
  Story 814 — Solo shipper sees the users who registered for their application.
  Criterion 6566 — The target app is unreachable.

  Surface: the project-scoped Users LiveView. When the outbound request to the
  target app fails to connect, Sam sees a clear "could not reach" error and no
  user list — never a blank list masquerading as "no users". The transport
  failure is simulated with a Req test stub.

  Red until the Users LiveView renders an explicit unreachable error state.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @client_api_url "https://unreachable.example.com"

  setup :register_log_in_setup_account
  setup :setup_active_project

  # Shared mode so the LiveView process (separate from the test) sees the stub.
  setup do
    Req.Test.set_req_test_to_shared(%{})
  end

  spex "Sam sees a clear error when his app is unreachable" do
    scenario "The target app is unreachable" do
      given_ "the project points at a target app that cannot be reached", context do
        {:ok, form_live, _html} = live(context.conn, "/app/projects/#{context.project.id}/edit")

        # deploy_key is a generate-only hidden field — click generate, then save.
        render_click(form_live, "generate_deploy_key", %{})

        form_live
        |> form("#project-form", project: %{client_api_url: @client_api_url})
        |> render_submit()

        # The client's outbound Req returns a transport error for this host.
        Req.Test.stub(CodeMySpec.ProjectUsers, fn conn ->
          Req.Test.transport_error(conn, :econnrefused)
        end)

        {:ok, context}
      end

      when_ "Sam opens the Users view", context do
        {:ok, _view, html} = live(context.conn, "/app/projects/#{context.project.id}/users")
        {:ok, Map.put(context, :html, html)}
      end

      then_ "he sees a clear error that the application could not be reached",
            context do
        assert context.html =~ "could not reach",
               "expected an explicit unreachable error, got: #{context.html}"

        {:ok, context}
      end

      then_ "no user list is shown", context do
        refute context.html =~ ~s(data-test="user-row"),
               "expected no user rows when the app is unreachable"

        {:ok, context}
      end
    end
  end
end
