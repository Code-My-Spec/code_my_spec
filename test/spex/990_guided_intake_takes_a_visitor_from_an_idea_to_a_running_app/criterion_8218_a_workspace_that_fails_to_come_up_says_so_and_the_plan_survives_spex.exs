defmodule CodeMySpecSpex.Story990.Criterion8218Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 8218 — A workspace that fails to come up says so and the plan survives.

  Rule: the workspace comes up and the visitor sees the running application.

  The failure side, and on day one it is the likeliest path rather than the
  rare one. What the visitor sees here is the whole difference between "this
  is broken" and "they are on it" — so a silent spinner is the defect, not
  the failure itself. The plan has to outlive the boot, because it is the
  thing they would otherwise have to build again.

  Surface: `/build` through the gate, then `/build/workspace` with an
  instance that dies instead of answering.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecTest.FakeWorkspaceRunner

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Workspaces,
      runner: FakeWorkspaceRunner,
      boot_timeout: 5_000,
      poll_interval: 20
    )

    # Never answers, and stops running — the container died on its way up.
    start_supervised!({FakeWorkspaceRunner, healthy?: false, alive?: false})
    on_exit(fn -> Application.delete_env(:code_my_spec, CodeMySpec.Workspaces) end)
    :ok
  end

  spex "A workspace that fails to come up says so, and the plan survives it" do
    scenario "A workspace that fails to come up says so and the plan survives" do
      given_ "a visitor who has confirmed a plan", context do
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

        {:ok, Map.put(context, :conn, conn)}
      end

      when_ "the workspace fails to come up", context do
        {:ok, view, _html} = live(context.conn, "/build/workspace")

        {:ok, Map.merge(context, %{view: view, html: await(view, "didn&#39;t come up")})}
      end

      then_ "they are told it failed rather than left on a spinner", context do
        assert context.html =~ "didn&#39;t come up",
               "expected the failure to be stated, got: #{context.html}"

        assert context.html =~ "stopped before it finished starting up",
               "expected the visitor to be told what happened, got: #{context.html}"

        {:ok, context}
      end

      then_ "their plan is still intact and they can try again", context do
        assert context.html =~ "Your plan is safe"
        assert context.html =~ "Try again"

        {:ok, context}
      end

      then_ "their account and project still exist", context do
        {:ok, _view, html} = live(context.conn, "/app")

        assert html =~ "Widget Tracker",
               "expected the project to survive a failed boot, got: #{html}"

        {:ok, context}
      end
    end
  end

  defp await(view, text, attempts \\ 400)

  defp await(view, text, 0), do: flunk("never rendered #{inspect(text)}: #{render(view)}")

  defp await(view, text, attempts) do
    html = render(view)

    case String.contains?(html, text) do
      true ->
        html

      false ->
        Process.sleep(20)
        await(view, text, attempts - 1)
    end
  end
end
