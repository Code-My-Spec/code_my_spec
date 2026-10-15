defmodule CodeMySpecSpex.Story1064.Criterion2203Spex do
  @moduledoc """
  Story 1064 — The product agent onboards me
  Criterion 2203 — Once the onboarding questions are answered and the project
  exists, the project's own main agent takes over the conversation, and it
  starts on the project's devops setup.

  ## Beyond "onboarding ends somewhere"

  Criterion 1327 in this story already drives confirming the plan through to
  a page with a project on it, and (per product, question 321a5627) now
  asserts the visitor lands on the project's own agent-conversation with
  `[data-test='main-agent']` — the same landing this criterion names. This
  spex reuses that exact drive (cloud + `start_workspace_runner`, the pattern
  criterion 1058/story 990 established, plus the platform credential
  criterion 2978/story 990 established) and adds this criterion's own,
  stronger claim: not just that *an* agent is there, but that it starts on
  devops setup.

  ## What stands for "starts on devops setup"

  Nothing on the agent-conversation page marks a devops-setup state the way
  `main-agent` marks the agent's identity — `main_summary/1`'s own comment
  says the agent is "what will write" the project's status in prose, by
  design, rather than a status assembled from rows. So the only honest
  surface for "starts on devops setup" is the agent's own first words, and
  this checks for them loosely (case-insensitively, on "devops" or "setup")
  rather than asserting exact copy no implementation has been held to yet.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  alias CodeMySpec.Agents.Credential

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)

    previous = Application.get_env(:code_my_spec, Credential)
    Application.put_env(:code_my_spec, Credential, platform_api_key: "sk-platform-2203")
    on_exit(fn -> restore_credential_env(previous) end)

    :ok
  end

  defp restore_credential_env(nil), do: Application.delete_env(:code_my_spec, Credential)
  defp restore_credential_env(config), do: Application.put_env(:code_my_spec, Credential, config)

  spex "the onboarding questions are answered and the project exists", criterion: 2203 do
    scenario "Main takes over once the project exists, for devops setup" do
      given_ "the onboarding questions are answered and the project exists", context do
        conn = get(context.conn, "/build")
        {:ok, live, _html} = live(conn)

        describe_idea(live, "a booking tool for a two-chair barbershop")
        answer_shaping_questions(live)

        destination = confirm_plan(live, %{location: "cloud"})

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:destination, destination)}
      end

      when_ "onboarding finishes", context do
        {:ok, workspace_live, _html} = live(context.conn, context.destination)
        render_hook(workspace_live, "payment_confirmed", %{})

        html = context.conn |> get("/app/projects") |> html_response(200)

        [_, project_id] =
          Regex.run(~r|/app/projects/([a-f0-9-]{36})|, html) ||
            raise("expected to find a project on /app/projects, got: #{html}")

        {:ok, live, html} =
          live(context.conn, "/app/projects/#{project_id}/agent-conversation")

        {:ok, context |> Map.put(:conversation_live, live) |> Map.put(:conversation_html, html)}
      end

      then_ "the project's main agent takes over the conversation", context do
        assert has_element?(context.conversation_live, "[data-test='main-agent']"),
               """
               The agent on this page is not identifiable as the project's main
               agent. Onboarding finishing has to hand the conversation to the
               agent that runs the project, not leave the visitor talking to
               whatever was asking the onboarding questions.
               """

        {:ok, context}
      end

      and_ "it starts on the project's devops setup", context do
        assert context.conversation_html =~ ~r/devops|setup/i,
               """
               Nothing on the page the visitor landed on says anything about
               devops or setup. Taking over silently is indistinguishable from
               not having anything to do yet.
               """

        {:ok, context}
      end
    end
  end
end
