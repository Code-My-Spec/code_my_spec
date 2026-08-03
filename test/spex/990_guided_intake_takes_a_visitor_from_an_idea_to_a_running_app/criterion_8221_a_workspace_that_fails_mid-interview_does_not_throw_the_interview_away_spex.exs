defmodule CodeMySpecSpex.Story990.Criterion8221Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 8221 — A workspace that fails mid-interview does not throw the
  interview away.

  Rule: the story interview starts on its own while the workspace is still
  coming up.

  Running the interview during the boot buys patience, but it also creates a
  way to lose someone that did not exist when the interview came afterwards:
  the thing they are doing can be destroyed by the thing happening behind it.
  Answers are written down as they are given, so a boot that dies takes
  nothing with it.

  Surface: `/build/workspace` with an instance that dies part-way through the
  conversation.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecTest.FakeWorkspaceRunner

  @endpoint CodeMySpecWeb.Endpoint

  @answer "clients must never see bookings from a different salon"

  setup :register_log_in_setup_account

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Workspaces,
      runner: FakeWorkspaceRunner,
      boot_timeout: 60_000,
      poll_interval: 20
    )

    start_supervised!({FakeWorkspaceRunner, healthy?: false, alive?: true})
    on_exit(fn -> Application.delete_env(:code_my_spec, CodeMySpec.Workspaces) end)
    :ok
  end

  spex "A failing workspace does not cost the visitor the interview" do
    scenario "A workspace that fails mid-interview does not throw the interview away" do
      given_ "a visitor part-way through the interview", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        view
        |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
        |> render_submit()

        view
        |> form("form[phx-submit=answer]", %{
          plan: %{needs_sign_in: "true", separate_copies: "true", who_uses: "salon owners"}
        })
        |> render_submit()

        view
        |> form("form[phx-submit=confirm_names]", %{
          plan: %{account_name: "Acme", project_name: "Widget Tracker"}
        })
        |> render_submit()

        {:ok, workspace_view, _html} = live(conn, "/build/workspace")

        workspace_view
        |> form("form[phx-submit=answer]", %{answer: @answer})
        |> render_submit()

        {:ok, Map.merge(context, %{conn: conn, view: workspace_view})}
      end

      when_ "the workspace dies under them", context do
        FakeWorkspaceRunner.put_alive(false)

        html = eventually(context.view, "didn&#39;t come up")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "they are told it failed", context do
        assert context.html =~ "didn&#39;t come up"

        {:ok, context}
      end

      then_ "the answer they already gave is still there", context do
        # Re-mount, the way a visitor who reloads after a failure would.
        {:ok, _view, html} = live(context.conn, "/build/workspace")

        assert html =~ @answer,
               "expected the answer given before the failure to survive it, got: #{html}"

        {:ok, context}
      end
    end
  end

  defp eventually(view, text, attempts \\ 250)

  defp eventually(view, text, 0), do: flunk("never rendered #{inspect(text)}: #{render(view)}")

  defp eventually(view, text, attempts) do
    html = render(view)

    case String.contains?(html, text) do
      true ->
        html

      false ->
        Process.sleep(20)
        eventually(view, text, attempts - 1)
    end
  end
end
