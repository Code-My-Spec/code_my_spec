defmodule CodeMySpecSpex.Story886.Criterion848Spex do
  @moduledoc """
  Story 886, criterion 848: the framed app keeps its session.

  This spec checks the server-controlled half: the pane's real preview
  address, framing headers, session cookie, subsequent requests, a form
  submission, and a LiveView update. QA must separately check in a real
  browser on the running candidate that the cookie is retained inside the
  iframe and its socket remains live. If that check cannot run, QA records
  why and repeats it on main after promotion.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.PreviewSessionApp

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = PreviewSessionApp.configure()
    :ok
  end

  spex "The framed app keeps its session", criterion: 848 do
    scenario "the app's cookie, form and LiveView work at the framed address" do
      given_ "Sam's running app is shown in our preview frame", context do
        :ok = Fixtures.workspace_in(context.scope, context.project.id, :running)
        {:ok, _view, page} = live(context.conn, "/build/preview")

        [src] =
          page
          |> Floki.parse_document!()
          |> Floki.find("[data-test=preview-frame]")
          |> Floki.attribute("src")

        {:ok, Map.merge(context, %{page: page, preview: URI.parse(src)})}
      end

      when_ "the framed app sets its cookie and opens a LiveView socket", context do
        first =
          Phoenix.ConnTest.build_conn()
          |> Map.put(:host, context.preview.host)
          |> Phoenix.ConnTest.dispatch(
            PreviewSessionApp.Endpoint,
            :get,
            context.preview.path || "/"
          )

        {:ok, app_view, initial} = live(first)
        {:ok, Map.merge(context, %{first: first, app_view: app_view, initial: initial})}
      end

      then_ "the preview is same-site, frameable, and its session cookie is usable", context do
        page_host = PreviewSessionApp.embedder_host()
        preview_host = context.preview.host
        assert String.ends_with?(preview_host, "." <> registrable_domain(page_host))
        assert context.page =~ "preview-frame"

        framing_page = get(recycle(context.conn), "/build/preview")
        [page_policy] = Plug.Conn.get_resp_header(framing_page, "content-security-policy")
        assert page_policy =~ "frame-src"

        assert page_policy =~
                 "#{context.preview.scheme}://*.#{registrable_domain(preview_host)}"

        refute Plug.Conn.get_resp_header(context.first, "x-frame-options") in [
                 ["DENY"],
                 ["SAMEORIGIN"]
               ]

        [app_policy] = Plug.Conn.get_resp_header(context.first, "content-security-policy")
        assert app_policy =~ "frame-ancestors"
        assert app_policy =~ page_host

        [cookie | _] = Plug.Conn.get_resp_header(context.first, "set-cookie")
        assert cookie =~ "SameSite=Lax"
        assert context.preview.scheme == "https"
        assert cookie =~ "secure"

        follow_up =
          context.first
          |> recycle()
          |> Phoenix.ConnTest.dispatch(
            PreviewSessionApp.Endpoint,
            :get,
            context.preview.path || "/"
          )

        assert follow_up.status == 200
        assert follow_up.req_cookies != %{}
        {:ok, Map.put(context, :follow_up, follow_up)}
      end

      then_ "a form submits and a live update reaches the same session", context do
        form = form(context.app_view, "form[phx-submit]")
        updated = render_submit(form, %{})
        assert is_binary(updated)
        assert updated != context.initial
        assert render(context.app_view) =~ updated
        {:ok, context}
      end
    end
  end

  defp registrable_domain(host) do
    host |> String.split(".") |> Enum.take(-2) |> Enum.join(".")
  end
end
