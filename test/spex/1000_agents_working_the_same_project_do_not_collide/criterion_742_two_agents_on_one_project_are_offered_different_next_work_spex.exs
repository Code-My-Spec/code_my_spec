defmodule CodeMySpecSpex.Story1000.Criterion742Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 742 — Two agents on one project are offered different next work.

  Rule: An agent's requirement graph is computed from the project's authored work
  and that agent's own files.

  Where the two halves of this story meet. The stories are shared (criterion 734)
  and the files are not (criterion 732), so the graph — which is computed from
  both — must come out differently per agent while still being about the same
  authored work. An agent that wrote the spec a requirement asks for should be
  offered the next thing; the one that has not written it should still be offered
  the spec.

  Get this wrong and the tool stops working in the ordinary case: two agents on
  one project are either handed identical work (so they duplicate or collide) or
  handed unrelated work (so they are not collaborating on anything).

  Surfaces: the MCP tool an agent calls to find its work, and the channel — a
  second working copy has to *be* one, joining and reporting a tree of its own,
  before there is anything for the graph to differ about.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @contract_version 1

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "One project, two file states, two answers" do
    scenario "Two agents on one project are offered different next work" do
      # A satisfied project, deliberately. With the project chain outstanding
      # both agents are correctly offered the *same* project-level work — a real
      # answer, and one that never reaches the component requirements this
      # criterion is about. The asymmetry only becomes visible once the graph has
      # got as far down as the files.
      given_ :synced_context_in_satisfied_project

      given_ "two agents are serving the same project from different working copies",
             context do
        # The second is a real working copy: it joins and reports a tree of its
        # own. Synthesising a scope with a made-up harness id would name a
        # checkout that has never described itself, and an empty file state would
        # then be indistinguishable from one nobody has ever scanned.
        {:ok, reply, socket} =
          UserSocket
          |> socket("harness_without_the_spec", %{scope: context.scope})
          |> subscribe_and_join(
            HarnessProjectChannel,
            "harness_project:#{context.project.id}",
            %{
              "contract_version" => @contract_version,
              "harness_id" => nil,
              "root" => "/workspace/without-the-spec",
              "label" => "the checkout that has not written the spec"
            }
          )

        other_id = reply["harness_id"] || reply[:harness_id]

        ref =
          Phoenix.ChannelTest.push(socket, "observations", %{
            "observations" => [
              %{
                "path" => "lib/unrelated.ex",
                "role" => "implementation",
                "fingerprint" => "unrelated",
                "mtime" => "2026-08-12T00:00:00.000000Z"
              }
            ]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, _summary, 1000)

        {:ok,
         context
         |> Map.put(:writer, context.scope)
         |> Map.put(:other, %{context.scope | active_harness_id: other_id})}
      end

      given_ "one has written the spec a requirement asks for and the other has not", context do
        # given: already true — `:synced_context_in_satisfied_project` wrote and
        # synced the spec into the first agent's working copy, and the given
        # above had the second report a tree without it. That is the only
        # difference between them: same project, same stories, same architecture.
        #
        # What this checks is that the difference is *visible to the graph*,
        # which is the premise the rest of the scenario rests on and the one
        # thing neither of those two steps proves on its own.
        assert component_work(context.writer) != "",
               "the first agent's graph has no component work at all, so there is no spec " <>
                 "requirement for either agent to differ about"

        {:ok, context}
      end

      when_ "each asks for its next requirement", context do
        {:ok,
         context
         |> Map.put(:writer_view, component_work(context.writer))
         |> Map.put(:other_view, component_work(context.other))}
      end

      then_ "the agent that wrote the spec is offered the following requirement", context do
        refute context.writer_view =~ "spec_file",
               "the agent that already wrote the spec was offered it again, so its own files " <>
                 "are not reaching its graph. Got: #{context.writer_view}"

        {:ok, context}
      end

      then_ "the other is still offered the spec", context do
        assert context.other_view =~ "spec_file",
               "the agent with a checkout that has no spec was not offered one, so it is " <>
                 "being credited with work done in a tree it cannot see — and will be sent " <>
                 "to write tests against a file that is not there. Got: #{context.other_view}"

        {:ok, context}
      end

      then_ "both are working the same authored stories", context do
        # The asymmetry must be in the files and nowhere else. Architecture is
        # authored work, so both agents must be looking at the same components —
        # if the graph partitioned those too, the two agents would be building
        # different applications, which criterion 734 forbids.
        assert components_offered(context.writer) == components_offered(context.other),
               "the two agents were offered work on different components. The asymmetry " <>
                 "here is supposed to be the files; the architecture is the project's.\n\n" <>
                 "wrote it:  #{inspect(components_offered(context.writer))}\n" <>
                 "the other: #{inspect(components_offered(context.other))}"

        {:ok, context}
      end
    end
  end

  # The work outstanding on the one component whose spec the two checkouts
  # disagree about.
  #
  # Narrowed twice, and both narrowings are load-bearing.
  #
  # To component requirements rather than `get_next_requirement`, because the
  # single next thing is one row off the top of a list ordered project-first: two
  # agents differing three rows down are both correctly told the same thing, and
  # the criterion then reads as failing when nothing is wrong.
  #
  # To `ExampleContext` rather than the whole list, because a real project has
  # other components that legitimately still need specs — `MyAppWeb.Application`
  # does, in both checkouts. Asking whether the string "spec_file" appears
  # anywhere answers a question about the project's backlog, not about whether
  # this agent's own files reached its graph.
  @component "ExampleContext"

  defp component_work(scope), do: scope |> outstanding() |> section_for(@component)

  # Which components either agent has work on at all. The architecture is the
  # project's, so this set is the half that must *not* differ — and comparing it
  # is what stops "they were offered different work" from passing because one
  # agent was offered nothing.
  defp components_offered(scope) do
    ~r/^## Component: (.+)$/m
    |> Regex.scan(outstanding(scope))
    |> Enum.map(fn [_, module] -> module end)
    |> Enum.sort()
  end

  defp outstanding(scope) do
    {:reply, response, _frame} =
      ListRequirements.execute(
        %{entity_type: "component", status: "unsatisfied", summary: false},
        %Frame{assigns: %{current_scope: scope}}
      )

    response_text(response)
  end

  # The mapper groups rows under `## Component: <module>`, so a section runs to
  # the next heading. A component with nothing outstanding has no heading at all,
  # which is itself an answer — "" means every requirement on it is satisfied.
  defp section_for(text, module) do
    text
    |> String.split(~r/^## /m)
    |> Enum.find("", &String.starts_with?(&1, "Component: #{module}\n"))
  end
end
