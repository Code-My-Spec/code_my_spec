defmodule CodeMySpecSpex.Story814.Criterion6562Spex do
  @moduledoc """
  Story 814 — Solo shipper sees the users who registered for their application.
  Criterion 6562 — The request carries the project's deploy key.

  Surface: the project-scoped Users LiveView. Loading the view issues an
  outbound request to the target app that must carry the project's deploy key
  as a Bearer token. A Req test stub captures the outbound request and forwards
  its Authorization header to the test process for assertion.

  Red until `CodeMySpec.ProjectUsers` sends the deploy key as a Bearer token.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @client_api_url "https://app.example.com"

  setup :register_log_in_setup_account
  setup :setup_active_project

  # Shared mode so the LiveView process (separate from the test) sees the stub.
  setup do
    Req.Test.set_req_test_to_shared(%{})
  end

  spex "The request to the target app carries the project's deploy key" do
    scenario "The request carries the project's deploy key" do
      given_ "the project has a deploy key and an HTTPS client API URL", context do
        {:ok, form_live, _html} = live(context.conn, "/app/projects/#{context.project.id}/edit")

        # deploy_key is a generate-only hidden field — generate one and capture it.
        html = render_click(form_live, "generate_deploy_key", %{})
        [_, deploy_key] = Regex.run(~r/project\[deploy_key\][^>]*value="([0-9a-f]+)"/, html)

        form_live
        |> form("#project-form", project: %{client_api_url: @client_api_url})
        |> render_submit()

        CodeMySpecSpex.Fixtures.stub_capturing_authorization(
          CodeMySpec.ProjectUsers,
          self(),
          ~s({"data":[],"page":1,"page_size":50,"total":0})
        )

        {:ok, Map.put(context, :deploy_key, deploy_key)}
      end

      when_ "CodeMySpec requests the user list from the target app", context do
        {:ok, _view, _html} = live(context.conn, "/app/projects/#{context.project.id}/users")
        {:ok, context}
      end

      then_ "the request includes the deploy key as a Bearer token", context do
        assert_received {:authorization, ["Bearer " <> token]}

        assert token == context.deploy_key,
               "expected the outbound request to carry the project's deploy key as a Bearer token"

        {:ok, context}
      end
    end
  end
end
