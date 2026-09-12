defmodule CodeMySpecSpex.Story1065.Criterion3393Spex do
  @moduledoc """
  Story 1065 — Every process an agent is expected to follow is written down
  Criterion 3393 — The prompt points at the detail it assumes.

  The rule:

  > The playbook for a task is findable from the task that needs it.

  ## The prompt is the surface, not the playbook

  The previous criterion is about a playbook pointing onwards. This one is
  about the thing an agent reads *first*: the prompt a task hands back when it
  starts. An agent never goes looking for a playbook it has not been told
  about, so a playbook that exists and is unreferenced is a playbook nobody
  reads.

  `start_three_amigos_session` is driven here because it is a task prompt
  reachable with nothing but a story — no requirement graph, no assignment, no
  component. The heavier prompts (`write_bdd_specs`, `fix_bdd_specs`) need a
  projected requirement to exist before they can be asked for, which would make
  this scenario mostly setup and only incidentally about the claim.

  ## What it already does, and what it does not

  The prompt does point at its own playbook — it names `three_amigos/workflow.md`
  and says to read it with `read_knowledge`. What it does not point at is the
  process the playbook assumes: that sealing satisfies a requirement which only
  exists once the story is ready for development and assigned somewhere. So
  this is expected to fail on the second assertion and pass on the first, which
  is the useful shape — it says the habit exists and is applied one level too
  shallow.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.StartThreeAmigosSession

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The prompt points at the detail it assumes" do
    scenario "an agent starts a task whose prompt assumes a process" do
      given_ "a story to run the task against", context do
        story =
          CodeMySpecSpex.Fixtures.authored_story(
            context.scope,
            "A story for a task prompt to be about"
          )

        {:ok, Map.put(context, :story, story)}
      end

      when_ "an agent starts the task and reads the prompt it is handed", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartThreeAmigosSession.execute(%{story_id: to_string(context.story.id)}, frame)

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt points at its own playbook", context do
        assert context.prompt =~ ~r/read_knowledge|workflow\.md/,
               "the prompt assumes a playbook and never names it, so an agent has to " <>
                 "already know the playbook exists in order to find it. Got:\n" <>
                 String.slice(context.prompt, 0, 400)

        {:ok, context}
      end

      then_ "and at the process that playbook assumes", context do
        assert context.prompt =~ ~r/#{Regex.escape("process/")}/,
               "the prompt points one level down — at the playbook for this task — and " <>
                 "not at the process around it. An agent that follows it will run the " <>
                 "session correctly and still not know that sealing satisfies a " <>
                 "requirement which does not exist until the story is ready for " <>
                 "development and assigned to a checkout."

        {:ok, context}
      end
    end
  end
end
