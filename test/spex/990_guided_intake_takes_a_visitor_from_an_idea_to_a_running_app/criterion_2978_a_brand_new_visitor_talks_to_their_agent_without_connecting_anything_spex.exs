defmodule CodeMySpecSpex.Story990.Criterion2978Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 2978 — A brand new visitor talks to their agent without
  connecting anything.

  Rule: the first conversation runs on our credential, not theirs.

  A visitor who signed up ninety seconds ago has connected no provider — no
  OpenAI key, no Anthropic key, nothing. Asking them to paste one before they
  can talk to the agent that is meant to be building their app for them would
  put a setup step back in front of exactly the visitor guided intake exists
  to spare it.

  ## What is asserted, and what deliberately is not

  Per 963/2905: a spex drives surfaces, not a model, so it cannot assert
  prose. What is asserted is that the main agent's conversation is offered —
  the visitor can say something to it — while nothing about connecting a
  provider was ever put in front of them.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  alias CodeMySpec.Agents.Credential

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)

    # Ours, configured — the same premise 990/2972 states: with nothing
    # connected, the honest behaviour is "connect a provider", which is a
    # different criterion from this one.
    previous = Application.get_env(:code_my_spec, Credential)
    Application.put_env(:code_my_spec, Credential, platform_api_key: "sk-platform-2978")

    on_exit(fn -> restore_credential_env(previous) end)

    :ok
  end

  defp restore_credential_env(nil), do: Application.delete_env(:code_my_spec, Credential)
  defp restore_credential_env(config), do: Application.put_env(:code_my_spec, Credential, config)

  spex "The first conversation runs without the visitor connecting anything" do
    scenario "A brand new visitor talks to their agent without connecting anything" do
      given_ "a visitor who signed up through intake and has connected no provider",
            context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        answer_shaping_questions(view)

        to = confirm_plan(view, %{location: "cloud"})

        assert to == "/build/workspace",
               "expected a signed-in visitor to be sent to their workspace, got #{inspect(to)}"

        {:ok, workspace_view, _html} = live(conn, to)

        # Cloud now pays before it provisions (990/3400) — not this
        # criterion's subject, so cleared the way the browser's own Stripe
        # hook would, to reach the running instance this scenario is about.
        html = render_hook(workspace_view, "payment_confirmed", %{})

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:workspace_html, html) |> Map.put(:workspace_view, workspace_view)}
      end

      when_ "their project comes up", context do
        project_id = find_new_project_id(context.conn)

        {:ok, _live, html} = live(context.conn, "/app/projects/#{project_id}/agent-conversation")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "an agent is running in it and answers them", context do
        assert context.html =~ "phx-submit=\"send_message\"",
               "expected the main agent's conversation to be offered on a project that has " <>
                 "just come up, got: #{context.html}"

        {:ok, context}
      end

      then_ "they were never asked to connect anything to get that far", context do
        refute context.workspace_html =~ ~r/connect (a |your )?provider/i,
               "the visitor was asked to connect a provider before their workspace even " <>
                 "showed them anything, got: #{context.workspace_html}"

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
