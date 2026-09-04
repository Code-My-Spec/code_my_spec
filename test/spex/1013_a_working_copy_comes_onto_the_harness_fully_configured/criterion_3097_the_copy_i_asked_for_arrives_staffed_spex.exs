defmodule CodeMySpecSpex.Story1013.Criterion3097Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 3097 — The copy I asked for arrives staffed.

  Rule: A working copy created this way comes up with its agents already on it.

  The end of John's sentence: *"give me a working copy, and we got a worktree,
  onboard it, and then the agents are up and running inside that worktree."*
  Creating a copy is not a step on the way to somewhere; it is the whole request,
  and it is finished when there is somebody in there to do the work.

  This meets story 964's rule from the other side. 964 says a copy given an epic
  comes up with its three agents; that rule cannot hold if nothing creates a copy
  to put them on, which is why 964's roster criteria are red today — a project's
  first epic lands on the main checkout, where `Agents.main_copy_is_free/2`
  refuses a roster and is right to.

  `Agents.ensure_copy_agents/2` already starts the three, idempotent by role.
  What is missing is a copy that is not the main one to call it against.

  ## Red on purpose

  `CreateWorkingCopy` does not exist.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Stories.Tools.CreateWorkingCopy
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A working copy created this way comes up with its agents already on it" do
    scenario "The copy I asked for arrives staffed" do
      given_ "a connected provider for the agents to run on", context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)

        {:ok, context}
      end

      when_ "I ask for a working copy for an epic", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateWorkingCopy.execute(%{label: "the war epic's copy"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "its product, coding and QA agents are on it", context do
        roles =
          context.scope
          |> Agents.list_agents()
          |> Enum.map(& &1.role)
          |> Enum.uniq()
          |> Enum.sort()

        for role <- [:coding, :product, :qa] do
          assert role in roles,
                 "the copy came up without a #{role} agent. Creating a copy is the " <>
                   "whole request and it is finished when somebody is in there to do " <>
                   "the work. Roles found: #{inspect(roles)}"
        end

        {:ok, context}
      end

      then_ "and I can reach each of them without doing anything else first", context do
        {:ok, _live, html} =
          Phoenix.LiveViewTest.live(
            context.conn,
            "/app/projects/#{context.project.id}/working-copies"
          )

        assert html =~ ~s(data-test="open-agent-chat"),
               "the agents are on the copy and there is no way to talk to any of " <>
                 "them. A roster I cannot address is a status display, not a team."

        {:ok, context}
      end
    end
  end
end
