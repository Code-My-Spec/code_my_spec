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

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Workspaces.PreviewAddress

  setup :register_log_in_setup_account
  setup :setup_active_project

  @self_run "https://preview-2969-selfrun.example.test"

  spex "One preview mechanism, whoever is running the app" do
    scenario "A visitor's hosted app and a founder's own checkout are reached the same way" do
      given_ "a founder whose app runs on their own machine", context do
        reply =
          join_working_copy(context, "/workspace/main", "main", preview_url: @self_run)

        {:ok, Map.put(context, :working_copy_id, reply.working_copy_id)}
      end

      when_ "the founder opens their project", context do
        {:ok, live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "the preview is framed at an address on our own domain", context do
        assert context.html =~ @self_run,
               "the self-run app's preview is not on the page at all"

        # The address has to stay ours whoever runs the app. `PreviewProxy`
        # recognises a preview by this prefix, the frame-src policy is derived
        # from the same base domain, and Safari drops a framed app's session
        # cookie across a registrable domain — so an app-chosen hostname breaks
        # three things at once, and only on some browsers.
        assert PreviewAddress.prefix() == "preview-",
               "the prefix the whole scheme keys on has moved; this spec and the " <>
                 "proxy no longer agree about what a preview address looks like"

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
