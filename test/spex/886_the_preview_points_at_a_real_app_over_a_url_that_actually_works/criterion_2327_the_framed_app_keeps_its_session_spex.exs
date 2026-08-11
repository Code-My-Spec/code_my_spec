defmodule CodeMySpecSpex.Story886.Criterion2327Spex do
  @moduledoc """
  Story 886 — The preview points at a real app, over a URL that actually works.
  Criterion 2327 — The framed app keeps its session.

  Rule: what the pane displays is served by the visitor's own app, not
  reproduced by us.

  This is the criterion the subdomain exists for, and the reason the preview
  is not simply an iframe pointed at a container's own address. Safari blocks
  third-party cookies by default. An app framed from a genuinely foreign
  origin loses its session cookie, and with the session goes the CSRF token
  and the LiveView connect — so the app renders once, logged out, and dies on
  the first click. The failure looks like a bug in the generated app, which is
  the worst possible place for it to look like.

  Serving the preview from a subdomain of our own registrable domain makes the
  frame same-site, so `SameSite=Lax` keeps working and the app behaves in the
  pane exactly as it does in a tab.

  Two things have to hold, and only the second is about our code: the address
  has to actually be same-site, and the proxy has to carry the cookie both
  ways without eating it.

  Surface: `CodeMySpecWeb.Plugs.PreviewProxy`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A framed preview keeps the app's session" do
    scenario "The framed app keeps its session" do
      given_ "the visitor's app is up and issues a session cookie", context do
        host = Fixtures.preview_app(context.scope, context.project.id)

        {:ok, Map.put(context, :preview_host, host)}
      end

      when_ "the preview address is opened", context do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Map.put(:host, context.preview_host)
          |> get("/")

        {:ok, Map.put(context, :response, conn)}
      end

      then_ "the preview is same-site with us, which is what keeps the cookie alive",
            context do
        # The mechanism, asserted directly rather than inferred. A preview on
        # someone else's registrable domain would pass every other assertion
        # in this file and still be logged out in Safari.
        assert String.ends_with?(context.preview_host, "." <> registrable_domain()),
               "the preview host #{context.preview_host} is not a subdomain of " <>
                 "#{registrable_domain()}, so the frame is third-party and Safari " <>
                 "will drop the app's session cookie"

        {:ok, context}
      end

      then_ "the app's cookie reaches the browser", context do
        set_cookie = Plug.Conn.get_resp_header(context.response, "set-cookie")

        assert Enum.any?(set_cookie, &String.contains?(&1, "_preview_app_session")),
               "the proxy swallowed the app's session cookie, got: #{inspect(set_cookie)}"

        {:ok, context}
      end

      then_ "and the cookie the browser sends back reaches the app", context do
        # The return leg. A proxy can relay Set-Cookie faithfully and still
        # strip Cookie on the way up, which fails identically from the
        # visitor's side and not at all from the app's logs.
        answer =
          Phoenix.ConnTest.build_conn()
          |> Map.put(:host, context.preview_host)
          |> Plug.Conn.put_req_header("cookie", "_preview_app_session=sam")
          |> get("/whoami")

        assert answer.resp_body =~ "session=sam",
               "the app did not receive the browser's cookie, it saw: #{answer.resp_body}"

        {:ok, context}
      end

      then_ "and the app's own refusal to be framed is not passed on", context do
        # A generated Phoenix app sends X-Frame-Options: DENY. There is no
        # syntax in that header for "this one origin", so relaying any value
        # refuses our own pane; frame-ancestors replaces it and names us.
        framed =
          Phoenix.ConnTest.build_conn()
          |> Map.put(:host, context.preview_host)
          |> get("/frame-guard")

        assert Plug.Conn.get_resp_header(framed, "x-frame-options") == [],
               "the app's X-Frame-Options was relayed, so the pane renders an empty box"

        assert [policy] = Plug.Conn.get_resp_header(framed, "content-security-policy")
        assert policy =~ "frame-ancestors"

        {:ok, context}
      end
    end
  end

  defp registrable_domain do
    Fixtures.preview_host("x") |> String.split(".") |> Enum.take(-2) |> Enum.join(".")
  end
end
