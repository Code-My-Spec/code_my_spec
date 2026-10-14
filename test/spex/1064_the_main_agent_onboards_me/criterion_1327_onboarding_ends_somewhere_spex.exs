defmodule CodeMySpecSpex.Story1064.Criterion3376Spex do
  @moduledoc """
  Story 1064 — The main agent onboards me
  Criterion 1327 — Confirming the plan produces a project and puts the person in
  front of the agent that runs it.

  ## Rewritten per product (2026-10-14, question 321a5627)

  The previous version of this spex asserted the destination stayed on an
  intake-style page (`intake-transcript`, `form[phx-submit=answer]`) after
  payment — that was `IntakeLive.Workspace`'s actual behaviour at the time,
  not what this criterion itself says. The criterion's own words are "there
  is a project, and they are in front of the agent that runs it" — nothing
  about staying on intake's own page, nothing about payment. "The agent that
  runs it" is the project's main agent, so this now checks the same landing
  criterion 2203 (story 1064) checks for: `/app/projects/:id/agent-conversation`
  with `[data-test='main-agent']`.

  ## Why cloud, with the fake workspace runner

  Criterion 1058 (story 990) already proves this is the accepted way to get
  a *working* main agent conversation in a spec: cloud's boot is something a
  spec can make complete, through `start_workspace_runner/2`, where local's
  cannot — local only gets a working copy once an actual external harness
  connects, which nothing in this test drives. Reusing that exact pattern
  rather than inventing a second one. Payment is kept because, for cloud, it
  is genuinely part of reaching the project: `gate_new_workspace/5` does not
  provision anything until it is confirmed.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)
    :ok
  end

  spex "the questions have been answered", criterion: 1327 do
    scenario "Onboarding ends somewhere" do
      given_ "the questions have been answered", context do
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

        {:ok, context}
      end

      then_ "there is a project", context do
        html = context.conn |> get("/app/projects") |> html_response(200)

        [_, project_id] =
          Regex.run(~r|/app/projects/([a-f0-9-]{36})|, html) ||
            raise("expected to find a project on /app/projects, got: #{html}")

        {:ok, Map.put(context, :project_id, project_id)}
      end

      and_ "they are in front of the agent that runs it", context do
        eventually(fn ->
          {:ok, live, _html} =
            live(context.conn, "/app/projects/#{context.project_id}/agent-conversation")

          assert has_element?(live, "[data-test='main-agent']"),
                 """
                 The visitor arrived somewhere with no identifiable agent running
                 the project. A project existing is only half of having arrived --
                 the other half is being in front of the thing that runs it.
                 """
        end)

        {:ok, context}
      end
    end
  end
end
