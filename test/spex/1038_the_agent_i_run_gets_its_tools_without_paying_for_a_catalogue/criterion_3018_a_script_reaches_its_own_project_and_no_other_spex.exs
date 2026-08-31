defmodule CodeMySpecSpex.Story1038.Criterion3018Spex do
  @moduledoc """
  Story 1038 — The agent I run gets its tools without paying for a catalogue.
  Criterion 3018 — A script reaches its own project and no other.

  Rule: A script acts with the authority of the agent that ran it.

  Code mode moves arbitrary code inside the tool boundary, so the boundary has
  to hold there. A script is not a new caller with its own permissions: it is
  the agent, and the agent belongs to one project.

  Both halves matter and the second is the one that leaks. A refusal that
  arrives carrying the other project's name, story title or id has already told
  the agent what it was refused, which is most of what it was asking for.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentToolsHelpers

    alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A script acts with the authority of the agent that ran it" do
    scenario "A script reaches its own project and no other" do
      given_ "an agent running for one project", context do
        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      given_ "and a story that belongs to somebody else", context do
        other = Fixtures.other_project_scope(context.scope, "not this agent's project")
        story = Fixtures.authored_story(other, "the other project's secret plan")

        {:ok, context |> Map.put(:other, other) |> Map.put(:their_story, story)}
      end

      when_ "its script asks for something belonging to another", context do
        script = "return get_story({ story_id = \"#{context.their_story.id}\" })"
        reply = Fixtures.run_script(script, agent_context(context))

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is refused", context do
        refute match?({:ok, _}, context.reply) and
                 elem(context.reply, 1) =~ context.their_story.title,
               "the script read another project's story. A script is the agent, and " <>
                 "the agent belongs to one project — otherwise code mode is a way " <>
                 "around the scope every tool already enforces."

        {:ok, context}
      end

      then_ "and nothing about the other project comes back", context do
        said = context.reply |> elem(1) |> to_string()

        refute said =~ context.their_story.title,
               "the refusal names the story it refused, which is most of what was " <>
                 "being asked for. Got: #{inspect(said)}"

        refute said =~ context.other.active_project_id,
               "the refusal carries the other project's id, so a script can enumerate " <>
                 "what exists by being told off about it. Got: #{inspect(said)}"

        {:ok, context}
      end
    end
  end
end
