defmodule CodeMySpecSpex.Story1057.Criterion3321Spex do
  @moduledoc """
  Story 1057 — The main agent sees the health of the machinery its agents
  depend on.
  Criterion 3321 — What the main agent can fix, it fixes.

  Rule: raising is for what is out of reach, not for everything.

  3312's counterweight, and the criterion that stops this story turning the main
  agent into a reporter. 3312 says a machinery fault is raised rather than
  restarted around; taken alone, the safe implementation of that is to raise
  everything — every refusal correct, every issue accurate, and nothing ever
  fixed.

  That failure is the most comfortable one available. It never breaks anything,
  it never restarts an agent that did not need it, and it turns a fleet that was
  supposed to look after itself into a queue of tickets for the person the whole
  thing exists to spare.

  ## The discrimination, in one scenario

  One agent is broken in a way a restart clears — its own process, on a machine
  that is otherwise fine. That is precisely 3311's shape, and it must produce the
  opposite action from 3312's: restart, and file nothing.

  Both halves are asserted. "Rather than reporting it" is not decoration: an
  implementation that restarts *and* raises has not distinguished anything, and
  the issue it files will be dismissed — which is how a list of real faults
  becomes one nobody reads.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A fault within reach is acted on, not filed" do
    scenario "one agent needs restarting on a machine that is otherwise fine" do
      given_ "an agent to restart on a checkout whose machinery is working",
             context do
        reply =
          join_working_copy(context, "/tmp/spex-3321", "the checkout",
            preview_url: "https://preview-3321.example.com"
          )

        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        {:ok, _integration} = Fixtures.connect_provider(scope, :zai)

        # The machine is fine — tools present, preview serving. Whatever is
        # wrong is the agent's own, which is the only case a restart reaches.
        Fixtures.record_machine_tools(scope, ["Read", "Write", "Bash"])
        Fixtures.record_preview_status(reply.working_copy_id, "serving")

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3321")

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent acts", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          RestartAgent.execute(
            %{agent_id: context.agent.id, reason: "it stopped answering its own turn"},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it restarts the agent", context do
        refute context.response.isError,
               """
               A fault the main agent could have fixed was refused instead.

               3312 says a machinery fault is raised rather than restarted
               around, and the safe implementation of that alone is to raise
               everything: every refusal correct, every issue accurate, and
               nothing ever fixed. That is the most comfortable failure
               available — it breaks nothing, and it turns a fleet that was
               supposed to look after itself into a queue of tickets for the
               person it exists to spare.

               reply:
               #{response_text(context.response)}
               """

        {:ok, context}
      end

      then_ "and nothing is raised about it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, issues, _frame} = ListIssues.execute(%{}, frame)

        assert response_text(issues) =~ ~r/no issues/i,
               """
               The main agent restarted the agent and filed an issue about it
               too.

               "Rather than reporting it" is the criterion, and it is not
               decoration: something both fixed and filed has not been
               distinguished from something that could not be fixed. The issue
               will be dismissed, and a list where the real faults sit among
               dismissible ones is a list nobody reads.

               issues:
               #{response_text(issues)}
               """

        {:ok, context}
      end
    end
  end
end
