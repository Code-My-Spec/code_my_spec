defmodule CodeMySpecSpex.Story841.Criterion1970Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1970 — DevOps off keeps the graph silent about infrastructure.

  Someone who has turned devops off is not running infrastructure through this
  tool, and the loop must not keep offering it work about servers. Silent means
  absent — not present-and-skipped, which still reads as part of the run.

  Surface: `get_next_requirement` MCP tool. The criterion is about what the
  loop offers, so the loop's own surface is where to ask.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_off

  spex "DevOps off keeps the graph silent about infrastructure" do
    scenario "devops is off, and the loop never mentions it" do
      given_ "a project with devops turned off", context do
        # Set here rather than left to the default. `:off` happens to be the
        # default today, and a scenario whose entire subject is what happens
        # when devops is off must not quietly start passing for a different
        # reason if that default ever changes.
        :ok = CodeMySpecSpex.Fixtures.set_devops(context.scope, :off)

        {:ok, context}
      end

      when_ "the loop asks for its next work", context do
        {:reply, response, _frame} =
          GetNextRequirement.execute(%{}, %Frame{assigns: %{current_scope: context.scope}})

        {:ok, Map.put(context, :next, response_text(response))}
      end

      then_ "the loop was offered work at all", context do
        # The contrast the refutes need. A reply that offered nothing — an
        # error, or a graph with no actionable work — contains none of the
        # infrastructure words either, so "the loop never mentions it" was
        # true of a loop that said nothing.
        assert context.next =~ "requirement_name=",
               "expected the graph to offer ordinary work with devops off, got:\n#{context.next}"

        {:ok, context}
      end

      then_ "no infrastructure work is offered", context do
        for word <- ~w(devops_setup deploy release provisioning) do
          refute context.next =~ word,
                 "expected the graph to stay silent about infrastructure with devops off, " <>
                   "but it mentioned #{word}: #{context.next}"
        end

        {:ok, context}
      end

      then_ "it is absent rather than listed as skipped", context do
        refute context.next =~ ~r/skip|not applicable|disabled/i,
               "a step shown as skipped still reads as part of the run"

        {:ok, context}
      end
    end
  end
end
