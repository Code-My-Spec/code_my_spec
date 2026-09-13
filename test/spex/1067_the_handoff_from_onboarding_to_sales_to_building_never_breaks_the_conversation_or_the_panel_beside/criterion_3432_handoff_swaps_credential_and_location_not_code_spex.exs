defmodule CodeMySpecSpex.Story1033.Criterion3432Spex do
  @moduledoc """
  Story 1033 — The handoff from onboarding to sales to building never breaks
  the conversation or the panel beside it.
  Criterion 3432 — Handoff swaps credential and location, not code.

  Rule, John 2026-09-12: "Only two things change at handoff: credential and
  execution location... No code branch differs between 'onboarding mode' and
  'real project mode' — only configuration does."

  ## What a spex can observe here, and what it cannot

  Which code path an agent runs, and on whose API credential, are facts
  about the running process — not something a rendered page exposes, and not
  something this suite reads by inspecting the implementation (per
  boundaries.md, a spex proves what the user sees, not what a row or a
  process holds). What is observable, and is the visitor-facing consequence
  of the rule holding: an agent is genuinely running *in the working copy
  itself* once it comes up — not still answering from wherever the
  pre-signup conversation ran. If handoff were a second, differently-coded
  agent bolted on afterward rather than the same one relocating,
  the most likely way that shows up is no agent actually running in the new
  copy at all.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  alias CodeMySpec.Agents.Credential

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)

    previous = Application.get_env(:code_my_spec, Credential)
    Application.put_env(:code_my_spec, Credential, platform_api_key: "sk-platform-3432")
    on_exit(fn -> restore_credential_env(previous) end)

    :ok
  end

  defp restore_credential_env(nil), do: Application.delete_env(:code_my_spec, Credential)
  defp restore_credential_env(config), do: Application.put_env(:code_my_spec, Credential, config)

  spex "The same agent relocates to the working copy rather than a second one appearing" do
    scenario "Handoff swaps credential and location, not code" do
      given_ "the pre-signup agent has been running on our credential, on our infrastructure",
            context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        answer_shaping_questions(view)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "the visitor's working copy comes up", context do
        to = confirm_plan(context.view, %{location: "cloud"})

        assert to == "/build/workspace",
               "expected a signed-in visitor to be sent to their workspace, got #{inspect(to)}"

        {:ok, workspace_view, _html} = live(context.conn, to)

        # Cloud now pays before it provisions (990/3400) — not this
        # criterion's subject, so cleared the way the browser's own Stripe
        # hook would, to reach the relocated agent this scenario is about.
        render_hook(workspace_view, "payment_confirmed", %{})

        project_id = find_new_project_id(context.conn)

        {:ok, Map.put(context, :project_id, project_id)}
      end

      then_ "the same agent code starts running on that working copy instead", context do
        {:ok, live, html} =
          live(context.conn, "/app/projects/#{context.project_id}/agent-conversation")

        assert html =~ "phx-submit=\"send_message\"",
               "expected the relocated agent to be running and talkable in the working " <>
                 "copy itself, got: #{html}"

        {:ok, context |> Map.put(:agent_live, live) |> Map.put(:agent_html, html)}
      end

      then_ "it runs on the customer's connected provider if they have one, or continues on our credential under the same turn cap if they do not",
            context do
        refute has_element?(context.agent_live, "[data-test='connect-provider-required']"),
               "the visitor with no connected provider was blocked rather than continuing " <>
                 "on our credential under the existing budget. Got: #{context.agent_html}"

        {:ok, context}
      end
    end
  end

  defp find_new_project_id(conn) do
    html = conn |> get("/app/projects") |> html_response(200)

    [_, id] =
      Regex.run(~r|/app/projects/([a-f0-9-]{36})|, html) ||
        raise("could not find any project link on /app/projects, got: #{html}")

    id
  end
end
