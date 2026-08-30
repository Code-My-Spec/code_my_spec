defmodule CodeMySpecSpex.Story1032.Criterion2991Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2991 — Naming another project in the script does not reach it

  A script supplies arguments, and arguments are not where authority comes
  from. Naming somebody else's story reaches nothing.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript
  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time" do
    scenario "Naming another project in the script does not reach it" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      given_ "another project has a story of its own", context do
        # Through the Fixtures bridge, which is the only sanctioned way a spex
        # reaches a second project — and a real foreign story is the point. A
        # made-up id would prove "no such story", which is a weaker claim than
        # the criterion makes.
        other = Fixtures.other_project_scope(context.scope, "somebody-elses-project")
        story = Fixtures.story_fixture(other, %{title: "Not yours to read"})

        {:ok, Map.put(context, :other_story, story)}
      end

      when_ "the script asks for the other project's story by id", context do
        script = ~s[local s, err = get_story({ story_id = "#{context.other_story.id}" })\nif s == nil then return "refused" end\nreturn s.title]

        {:reply, response, _frame} = RunScript.execute(%{script: script}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it is refused exactly as a direct call would be", context do
        assert response_text(context.response) =~ "refused"
        {:ok, context}
      end

      then_ "and nothing about the other project comes back", context do
        refute response_text(context.response) =~ "Not yours to read"
        {:ok, context}
      end
    end
  end
end
