defmodule CodeMySpecSpex.Story814.Criterion6567Spex do
  @moduledoc """
  Story 814 — Solo shipper sees the users who registered for their application.
  Criterion 6567 — The target app rejects the deploy key.

  Surface: the project-scoped Users LiveView. When the target app responds 401
  (the deploy key doesn't match what the app expects), Sam sees an
  authentication error instead of user data. Outbound 401 simulated with a Req
  test stub.

  Red until the Users LiveView renders an explicit auth-error state.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @client_api_url "https://app.example.com"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam sees an auth error when the deploy key is rejected" do
    scenario "The target app rejects the deploy key" do
      given_ "the project's deploy key does not match the target app", context do
        {:ok, form_live, _html} = live(context.conn, "/app/projects/#{context.project.id}/edit")

        # deploy_key is a generate-only hidden field — click generate, then save.
        render_click(form_live, "generate_deploy_key", %{})

        form_live
        |> form("#project-form", project: %{client_api_url: @client_api_url})
        |> render_submit()

        Req.Test.stub(CodeMySpec.ProjectUsers, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(401, ~s({"error":"Invalid deployment key"}))
        end)

        {:ok, context}
      end

      when_ "Sam opens the Users view", context do
        {:ok, _view, html} = live(context.conn, "/app/projects/#{context.project.id}/users")
        {:ok, Map.put(context, :html, html)}
      end

      then_ "he sees an authentication error instead of user data", context do
        assert context.html =~ "authentication",
               "expected an authentication error message"

        refute context.html =~ ~s(data-test="user-row"),
               "expected no user rows when the deploy key is rejected"

        {:ok, context}
      end
    end
  end
end
