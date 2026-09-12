defmodule CodeMySpecSpex.Story990.Criterion3405Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 3405 — The conversation is already going when the visitor arrives.

  (Written under this story's earlier numbering as criterion 2972; renamed
  to track the criterion after a Three Amigos renumbering. Same scenario,
  same file history.)

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

  alias CodeMySpec.Agents.Credential

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)

    # Our credential, configured. A visitor who signed up ninety seconds ago has
    # connected no provider, so the first conversation runs on ours — and it is
    # off unless configured, deliberately, because it spends real money. Stated
    # here because it is the deployment this criterion describes: with nothing
    # configured the honest behaviour is "connect a provider", which is a
    # different criterion.
    previous = Application.get_env(:code_my_spec, Credential)
    Application.put_env(:code_my_spec, Credential, platform_api_key: "sk-platform-2972")

    on_exit(fn -> restore_credential_env(previous) end)

    :ok
  end

  defp restore_credential_env(nil), do: Application.delete_env(:code_my_spec, Credential)
  defp restore_credential_env(config), do: Application.put_env(:code_my_spec, Credential, config)

  spex "The visitor lands in a conversation rather than in front of a button" do
    scenario "The conversation is already going when the visitor arrives" do
      given_ "a visitor whose working copy has just come up", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        answer_shaping_questions(view)

        confirm_plan(view, %{location: "cloud"})

        {:ok, view, _html} = live(conn, "/build/workspace")
        await(view, ~r/running/i)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "they look at the copy their project runs in", context do
        # Their working copies, which is the page that says what is running in
        # each one. Reached the way they would reach it rather than by a path
        # this spec knows.
        {:ok, live, html} = live(context.conn, working_copies_path(context.conn))

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "an agent is already running in that copy", context do
        # Not `data-test="agent-chip"` — the per-agent chip row on this page
        # was dropped as redundant with the liveness line directly above it,
        # which already says how many agents and what they're doing. "no
        # agent reported on this copy" is the one basis string
        # `Liveness.working_copy/2` returns when there is nothing there; every
        # other state (Starting, Running, Last heard from) means an agent
        # exists, which is the actual claim this criterion makes.
        refute context.html =~ "no agent reported on this copy",
               "the copy shows no agent, so nothing was started in the one that was " <>
                 "just provisioned. The visitor has spent all of intake in a " <>
                 "conversation and now has to press a button to continue one. " <>
                 "Got: #{context.html}"

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

  # The route the visitor walks to their copies: their projects, into the one
  # they just made, then "Working copies" in its nav.
  defp working_copies_path(conn) do
    project = follow(conn, "/app/projects", ~r|/app/projects/[a-f0-9-]{36}"|, "their projects")

    follow(conn, project, ~r|/app/projects/[^"]+/working-copies|, "the project")
  end

  defp follow(conn, from, pattern, what) do
    html = conn |> get(from) |> html_response(200)
    path_from(Regex.run(pattern, html), what)
  end

  defp path_from([path], _what), do: String.trim_trailing(path, ~s("))
  defp path_from(nil, what), do: flunk("nothing on #{what} leads to the visitor's cloud project.")

  defp await(view, pattern, attempts \\ 250)

  defp await(view, pattern, 0),
    do: flunk("never rendered #{inspect(pattern)}: #{render(view)}")

  defp await(view, pattern, attempts) do
    html = render(view)
    await_result(html =~ pattern, html, view, pattern, attempts)
  end

  defp await_result(true, html, _view, _pattern, _attempts), do: html

  defp await_result(false, _html, view, pattern, attempts) do
    Process.sleep(20)
    await(view, pattern, attempts - 1)
  end
end
