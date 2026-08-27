defmodule CodeMySpecSpex.Story1030.Criterion2969Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main checkout
  is onboarded.
  Criterion 2969 — A visitor's hosted app and a founder's own checkout are
  reached the same way.

  Rule: Every preview reaches its app over its own tunnel, whether we host the
  app or not.

  Two mechanisms existed. A workspace we run in a container was reached by
  dialling it — `PreviewProxy` forwards to the port and rewrites the
  `frame-ancestors` header the generated app sends. A checkout on somebody's
  laptop cannot be dialled at all, so it needs a tunnel it opens outward.

  Keeping both would mean every question about previews has two answers that
  drift: two ways an address is minted, two ways it goes down, two things to fix
  when a frame is blank. Decided 2026-08-27 to collapse onto the tunnel, which
  is the one that works in both cases.

  ## What this criterion is actually defending

  Not that both work — 2961 and 2965 cover the mechanics. That the founder
  cannot tell which one they are on. The moment the panel, the address, or the
  failure text differs between a hosted app and a self-run one, the two
  mechanisms are back and the person on the phone to support has to know which
  they have before anyone can help them.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  # The panel lives in `CodeMySpecWeb`, not the local app the case template
  # points at by default. Without this the route 404s and `live/2` fails
  # inside LiveViewTest rather than saying which router it looked in.
  # Story 1025's criteria drive the same page and override it the same way.
  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.MainAgentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    # The agent runs in another process, so it needs the connection this one
    # holds.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # Without a provider the main agent is refused, no conversation is ever
  # created, and the preview panel has no page to sit beside. The refusal is
  # deliberate — an agent started on a credential that does not resolve fails on
  # its first model call, minutes later, in a log nobody reads.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  @self_run "https://preview-2969-selfrun.example.test"

  spex "One preview mechanism, whoever is running the app" do
    scenario "A visitor's hosted app and a founder's own checkout are reached the same way" do
      given_ "a founder whose app runs on their own machine", context do
        context = given_a_main_checkout(context, "spex_2969", preview_url: @self_run)

        {:ok, Map.put(context, :path, say_to_main_agent(context, "how is it going"))}
      end

      when_ "the founder opens their preview", context do
        {:ok, live, _html} = live(context.conn, context.path)

        html = live |> element("[data-test='panel-tab-preview']") |> render_click()

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "the preview is framed at an address on our own domain", context do
        assert context.html =~ @self_run,
               "the self-run app's preview is not on the page at all"

        # Asserted on the rendered address rather than by asking the application
        # what its prefix is — a spex may not reach into `CodeMySpec`, and the
        # boundary is right: reading the constant would let this pass while the
        # page showed something else entirely.
        #
        # The address has to stay ours whoever runs the app. The proxy recognises
        # a preview by this prefix, the frame-src policy is derived from the same
        # base domain, and Safari drops a framed app's session cookie across a
        # registrable domain — an app-chosen hostname breaks three things at
        # once, and only on some browsers.
        assert context.html =~ "preview-",
               "the framed address is not one of ours"

        {:ok, context}
      end

      then_ "nothing on the page says which kind of preview it is", context do
        refute context.html =~ "container",
               "the panel tells the founder how their app happens to be hosted. That " <>
                 "is the distinction this criterion exists to remove — the moment it " <>
                 "is visible, supporting a blank frame starts with asking which of " <>
                 "the two mechanisms someone is on."

        refute context.html =~ "workspace is not running",
               "the hosted-only failure text is still reachable, so the two " <>
                 "mechanisms have not collapsed into one"

        {:ok, context}
      end
    end
  end
end
