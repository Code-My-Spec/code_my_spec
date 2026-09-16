defmodule CodeMySpecSpex.Story814.Criterion6560Spex do
  @moduledoc """
  Story 814 — Solo shipper sees the users who registered for their application.
  Criterion 6560 — Sam views his registered users.

  Surface: `CodeMySpecWeb.ProjectUsersLive.Index`. The list is read live from the
  target app; the outbound response is the real recording in
  `test/cassettes/project_users/list.json` (captured from dev.get-ai-traffic.com
  — 24 real users, deploy key redacted), replayed through `Req.Test` shared mode
  (the LiveView runs in a separate process).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.RealDisk

  @endpoint CodeMySpecWeb.Endpoint
  @client_api_url "https://app.example.com"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam sees the users who registered for his application" do
    scenario "Sam views his registered users" do
      given_ "the project points at a reachable target app with a deploy key", context do
        {:ok, form_live, _html} = live(context.conn, "/app/projects/#{context.project.id}/edit")

        # deploy_key is a generate-only hidden field — click generate, then save.
        render_click(form_live, "generate_deploy_key", %{})

        form_live
        |> form("#project-form", project: %{client_api_url: @client_api_url})
        |> render_submit()

        body = cassette_response_body("list")

        Req.Test.stub(CodeMySpec.ProjectUsers, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, body)
        end)

        {:ok, context}
      end

      when_ "Sam opens the Users view for his project", context do
        {:ok, _view, html} = live(context.conn, "/app/projects/#{context.project.id}/users")
        {:ok, Map.put(context, :html, html)}
      end

      then_ "he sees registered users listed with email and registration date", context do
        assert context.html =~ "qa@example.com",
               "expected a registered user's email in the list, got: #{context.html}"

        assert context.html =~ "2026-06-06",
               "expected each user's registration date rendered"

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
