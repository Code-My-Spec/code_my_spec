defmodule CodeMySpecSpex.Story990.Criterion2972Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 2972 — The conversation is already going when the visitor arrives.

  Rule: An agent is working in the visitor's copy by the time they are looking
  at it.

  The visitor has spent the whole of intake in a conversation — describing an
  idea, answering questions, correcting names. Landing them on a project with a
  "start an agent" button asks them to do a setup step, at the exact moment the
  product is supposed to be proving it removes them.

  John: "start an agent in there immediately to start the conversation with the
  user."

  ## Cheap now, and it was not always

  Starting an agent used to mean a detached OS process, a held stdin pipe and a
  reaper — the reason story 956 was hard. It is an Alloy loop in the harness
  now, beside the working copy, so starting one at boot is a supervisor child
  rather than a subsystem.

  ## What is asserted, and what deliberately is not

  That the visitor can say something without starting anything first. Not that
  the agent has *said* anything — that depends on a model call, and a criterion
  that waited on one would be testing the provider's latency.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)

    :ok
  end

  spex "The visitor lands in a conversation rather than in front of a button" do
    scenario "The conversation is already going when the visitor arrives" do
      given_ "a visitor whose working copy has just come up", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        answer_shaping_questions(view)

        view
        |> form("form[phx-submit=choose_location]", %{location: "cloud"})
        |> render_submit()

        {:ok, view, _html} = live(conn, "/build/workspace")
        await(view, ~r/running/i)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "they open their project", context do
        {:ok, live, html} = live(context.conn, ~p"/app/projects")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "an agent is already running in that copy", context do
        assert context.html =~ ~r/agent/i,
               "the project shows no agent, so nothing was started in the copy that " <>
                 "was just provisioned. The visitor has spent all of intake in a " <>
                 "conversation and now has to press a button to continue one."

        {:ok, context}
      end

      then_ "they can say something to it without starting anything first", context do
        refute context.html =~ ~r/start (an )?agent/i,
               "the visitor is being offered a control to start an agent, which is " <>
                 "the setup step this criterion exists to remove. Got: #{context.html}"

        {:ok, context}
      end
    end
  end

  defp await(view, pattern, attempts \\ 250)

  defp await(view, pattern, 0),
    do: flunk("never rendered #{inspect(pattern)}: #{render(view)}")

  defp await(view, pattern, attempts) do
    html = render(view)

    if html =~ pattern do
      html
    else
      Process.sleep(20)
      await(view, pattern, attempts - 1)
    end
  end
end
