defmodule CodeMySpecSpex.Story814.Criterion6568Spex do
  @moduledoc """
  Story 814 — Solo shipper sees the users who registered for their application.
  Criterion 6568 — Sam pages through a large user list.

  Surface: `CodeMySpecWeb.ProjectUsersLive.Index`. When the target app reports
  more users than fit on one page, the view shows the first page and a control
  to advance. The outbound response is the real recording in
  `test/cassettes/project_users/first_page.json` (captured from
  dev.get-ai-traffic.com at page_size 10 — 10 of 24 real users, deploy key
  redacted), replayed through `Req.Test` shared mode.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.RealDisk

  @endpoint CodeMySpecWeb.Endpoint
  @client_api_url "https://app.example.com"

  setup :register_log_in_setup_account
  setup :setup_active_project

  # Shared mode so the LiveView process (separate from the test) sees the stub.
  setup do
    Req.Test.set_req_test_to_shared(%{})
  end

  spex "Sam pages through his registered users" do
    scenario "Sam pages through a large user list" do
      given_ "the project points at a target app with more users than one page",
             context do
        {:ok, form_live, _html} = live(context.conn, "/app/projects/#{context.project.id}/edit")

        # deploy_key is a generate-only hidden field — click generate, then save.
        render_click(form_live, "generate_deploy_key", %{})

        form_live
        |> form("#project-form", project: %{client_api_url: @client_api_url})
        |> render_submit()

        body = cassette_response_body("first_page")

        Req.Test.stub(CodeMySpec.ProjectUsers, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, body)
        end)

        {:ok, context}
      end

      when_ "Sam opens the Users view", context do
        {:ok, _view, html} = live(context.conn, "/app/projects/#{context.project.id}/users")
        {:ok, Map.put(context, :html, html)}
      end

      then_ "he sees the first page of users", context do
        assert context.html =~ "qa@example.com",
               "expected the first page of users to render, got: #{context.html}"

        {:ok, context}
      end

      then_ "he can navigate to the next page", context do
        assert context.html =~ ~s(data-test="users-next-page"),
               "expected a next-page control when more users exist than fit on one page"

        {:ok, context}
      end
    end
  end

  defp cassette_response_body(name) do
    ["test", "cassettes", "project_users", "#{name}.json"]
    |> Path.join()
    |> RealDisk.read!()
    |> Jason.decode!()
    |> get_in(["interactions", Access.at(0), "response", "body"])
  end
end
