defmodule CodeMySpecSpex.Story886.Criterion2324Spex do
  @moduledoc """
  Story 886 — The preview points at a real app, over a URL that actually works.
  Criterion 2324 — The pane shows the running app itself.

  Rule: what the pane displays is served by the visitor's own app, not
  reproduced by us.

  The whole reason this story exists rather than stopping at story 1000's
  self-contained component. A pane that renders our idea of the app is a
  screenshot: convincing until Sam clicks, and worse than nothing when it
  disagrees with what was actually built.

  So the assertion is about provenance, not appearance. The bytes on the
  screen have to have come off the app's own socket, and the way to know is
  to serve something only the app could have said and find it in the
  response.

  The app here is a real HTTP server on a real port — see
  `Fixtures.preview_app/3`. Stubbing the client instead would assert that our
  proxy calls a function, which is not the claim.

  Surface: `CodeMySpecWeb.Plugs.PreviewProxy`, reached at
  `preview-{project_id}.codemyspec.com`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The preview serves the visitor's own app" do
    scenario "The pane shows the running app itself" do
      given_ "the visitor's app is up and serving something only it would say",
             context do
        host =
          Fixtures.preview_app(context.scope, context.project.id,
            body: "<h1>Widget Tracker</h1><p>Built for Sam</p>"
          )

        {:ok, Map.put(context, :preview_host, host)}
      end

      when_ "the preview address is opened", context do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Map.put(:host, context.preview_host)
          |> get("/")

        {:ok, Map.put(context, :response, conn)}
      end

      then_ "the app's own markup comes back", context do
        assert context.response.status == 200,
               "the preview did not reach the app, got #{context.response.status}: " <>
                 context.response.resp_body

        assert context.response.resp_body =~ "Widget Tracker"
        assert context.response.resp_body =~ "Built for Sam"

        {:ok, context}
      end

      then_ "and the response describes the body we actually forwarded", context do
        # A relayed content-length from upstream describes the app's body, not
        # ours, and the two differ the moment anything is rewritten. A browser
        # believes the header over the socket and truncates.
        declared = Plug.Conn.get_resp_header(context.response, "content-length")

        assert declared == [] or
                 declared == [Integer.to_string(byte_size(context.response.resp_body))],
               "content-length disagrees with the body sent: #{inspect(declared)} vs " <>
                 "#{byte_size(context.response.resp_body)} bytes"

        {:ok, context}
      end
    end
  end
end
