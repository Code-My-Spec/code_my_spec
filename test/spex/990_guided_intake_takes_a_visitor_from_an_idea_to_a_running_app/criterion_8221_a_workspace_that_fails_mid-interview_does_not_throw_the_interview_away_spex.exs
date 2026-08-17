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

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  @answer "clients must never see bookings from a different salon"

  setup :register_log_in_setup_account

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Workspaces,
      runner: CodeMySpecSpex.Case.workspace_runner(),
      boot_timeout: 60_000,
      poll_interval: 20
    )

    start_supervised!({CodeMySpecSpex.Case.workspace_runner(), healthy?: false, alive?: true})

    on_exit(fn ->
      Application.delete_env(:code_my_spec, :fake_workspace_alive)
      Application.delete_env(:code_my_spec, CodeMySpec.Workspaces)
    end)

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
        |> answer_shaping_questions()

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
        Application.put_env(:code_my_spec, :fake_workspace_alive, false)

        html = until_rendered(context.view, "didn&#39;t come up")

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

  # `eventually/2` from the Case, which owns the deadline. The local version
  # counted attempts, and a count is only a duration when the body is instant.
  defp until_rendered(view, text) do
    eventually(fn ->
      html = render(view)
      assert html =~ text
      html
    end)
  end
end
