defmodule CodeMySpecSpex.Story990.Criterion3406Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 3406 — Asking the box for an instance is all it takes.

  Rule: one ask produces a whole running instance — generated, onboarded,
  started, with an agent already in it — not four things a human strings
  together by hand.

  990/8217 already proves the workspace comes up running the visitor's
  application, and 990/2972 already proves an agent is running in it once it
  does. Neither states the thing this criterion is actually about: that both
  are the consequence of the *same single action* — confirming the plan — with
  nothing in between that reads as a person operating the box. This scenario
  is the composite: one action, both results, and no manual step shown for
  either.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  alias CodeMySpec.Agents.Credential

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    # "A development box already running and serving other people's
    # instances" — the fake runner standing in for a box that is already up,
    # exactly as 990/2970 and 990/8217 do.
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)

    previous = Application.get_env(:code_my_spec, Credential)
    Application.put_env(:code_my_spec, Credential, platform_api_key: "sk-platform-3406")
    on_exit(fn -> restore_credential_env(previous) end)

    :ok
  end

  defp restore_credential_env(nil), do: Application.delete_env(:code_my_spec, Credential)
  defp restore_credential_env(config), do: Application.put_env(:code_my_spec, Credential, config)

  spex "One ask is all it takes to get a running, agent-populated instance" do
    scenario "Asking the box for an instance is all it takes" do
      given_ "a visitor at the plan for what they described", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        answer_shaping_questions(view)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "a new project needs an instance on it", context do
        to = confirm_plan(context.view, %{location: "cloud"})

        assert to == "/build/workspace",
               "expected confirming the plan to be the one action that asks for an " <>
                 "instance, got #{inspect(to)}"

        {:ok, view, _html} = live(context.conn, to)

        # Cloud now pays before it provisions (990/3400) — clearing it the
        # way the browser's own Stripe hook would is the "ask" this
        # criterion is about; what happens after is still the one call this
        # scenario asserts on.
        html = render_hook(view, "payment_confirmed", %{})

        {:ok, context |> Map.put(:workspace_view, view) |> Map.put(:workspace_html, html)}
      end

      then_ "the harness generates, onboards, starts it, and puts an agent in it", context do
        html =
          eventually(fn ->
            html = render(context.workspace_view)
            assert html =~ ~r/it&#39;s running/i, "still waiting on the workspace: #{html}"
            html
          end)

        project_id = find_new_project_id(context.conn)
        {:ok, _live, agent_html} = live(context.conn, "/app/projects/#{project_id}/agent-conversation")

        assert agent_html =~ "phx-submit=\"send_message\"",
               "expected an agent already in the instance, ready to talk, got: #{agent_html}"

        {:ok, Map.put(context, :html, html)}
      end

      then_ "nothing outside the box had to run a command or hold a credential", context do
        refute context.html =~ ~r/mix cms\.new|mix harness\.onboard|ssh /,
               "the visitor was shown a command to run themselves, which is exactly the " <>
                 "manual step this criterion says the box does on its own. Got: #{context.html}"

        {:ok, context}
      end
    end
  end

  defp find_new_project_id(conn) do
    html = conn |> get("/app/projects") |> html_response(200)

    case Regex.run(~r|/app/projects/([a-f0-9-]{36})|, html) do
      [_, id] -> id
      nil -> flunk("could not find any project link on /app/projects, got: #{html}")
    end
  end
end
