defmodule CodeMySpecSpex.Story886.Criterion2328Spex do
  @moduledoc """
  Story 886 — The preview points at a real app, over a URL that actually works.
  Criterion 2328 — A change in the app reaches the pane without a reload.

  Rule: what the pane displays is served by the visitor's own app, not
  reproduced by us.

  The failure this rules out is the convincing one. A preview that proxies
  ordinary requests and drops the LiveView socket renders perfectly and is
  completely dead: the first render arrives, nothing after it does, and the
  pane shows a screenshot of a working application. Sam finds out by clicking,
  which is exactly when a preview is supposed to be earning its keep.

  So both directions are asserted, and the unprompted one is the point.
  Anything can be made to work when a reply follows a request; LiveView
  updates arrive because the app decided to send them, and a proxy that only
  pumps on inbound traffic passes a request/response test and still leaves the
  pane frozen.

  ## No browser

  This opens a real socket over a real port and speaks the real handshake —
  `Phoenix.ConnTest` never opens one, so the proxy's upgrade path is
  unreachable from it. It does not need a browser: the claim is that frames
  cross intact, and a client that speaks the protocol settles that. A driver
  would answer the same question far more slowly, and sit in the path of every
  other spec in the suite.

  The port is OS-assigned. A fixed one collides the moment two specs run
  together, and this suite runs twenty at a time.

  Surface: `CodeMySpecWeb.Plugs.PreviewProxy` and `CodeMySpecWeb.PreviewSocket`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  # No `@endpoint` override, unlike its five siblings, and deliberately: this
  # criterion makes no ConnTest call at all. It addresses the preview listener
  # by port and Host header over a socket it opens itself, so there is no
  # endpoint to resolve and an override here would only be decoration.
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The preview stays live, not just rendered" do
    scenario "A change in the app reaches the pane without a reload" do
      given_ "the visitor's app is up, with its LiveView socket serving", context do
        host = Fixtures.preview_app(context.scope, context.project.id)
        port = Fixtures.preview_endpoint()

        {:ok, Map.merge(context, %{preview_host: host, preview_port: port})}
      end

      when_ "the pane opens the app's socket through the preview address", context do
        {:ok, client} =
          Fixtures.open_preview_socket(context.preview_port, context.preview_host)

        {:ok, Map.put(context, :client, client)}
      end

      then_ "the app's unprompted first push arrives", context do
        # Nothing was sent up to provoke this. It is the direction a
        # request/response proxy gets wrong while looking correct.
        {:ok, frames, client} = Fixtures.preview_frames(context.client)

        assert Enum.any?(frames, &match?({:text, "hello from the app"}, &1)),
               "the app pushed and the pane never heard it — a framed app that " <>
                 "renders once and never updates, got: #{inspect(frames)}"

        {:ok, Map.put(context, :client, client)}
      end

      then_ "and what the pane sends reaches the app", context do
        {:ok, client} = Fixtures.send_preview_frame(context.client, "sam clicked something")
        {:ok, frames, client} = Fixtures.preview_frames(client)

        assert Enum.any?(frames, &match?({:text, "app saw: sam clicked something"}, &1)),
               "the app never saw the pane's frame, so every click in the preview is " <>
                 "swallowed, got: #{inspect(frames)}"

        {:ok, Map.put(context, :client, client)}
      end

      then_ "and the frames arrive as the app sent them, not re-encoded", context do
        # The proxy relays frames without interpreting them. LiveView's
        # protocol is its own business, and a proxy that understood it would be
        # a proxy that could get it wrong.
        {:ok, client} = Fixtures.send_preview_frame(context.client, ~s({"event":"phx_join"}))
        {:ok, frames, client} = Fixtures.preview_frames(client)

        assert Enum.any?(frames, &match?({:text, ~s(app saw: {"event":"phx_join"})}, &1)),
               "a payload came back altered, got: #{inspect(frames)}"

        Fixtures.close_preview_socket(client)

        {:ok, context}
      end
    end
  end
end
