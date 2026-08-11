defmodule CodeMySpecSpex.Story841.Criterion1963Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1963 — A story that clears QA rides to UAT.

  The criterion: the loop's next work after `qa_complete` is the UAT deploy,
  health-verified; prod promotion belongs to the release process.

  Surface: `get_next_requirement` MCP tool — the loop's own way of asking what
  is next. The criterion is a claim about what the loop does after QA passes,
  so the loop's surface is where it has to be asked.

  ## This is expected to fail, and the failure is the point

  `deploy` was removed from the requirement graph in d207ad38 along with
  `devops_setup` and `release`, because all three gated on markdown the agent
  wrote for itself. So the loop cannot currently hand out a UAT deploy: there
  is no node to hand out.

  Encoded as the criterion reads rather than softened to match the code,
  because the two genuinely disagree and that disagreement is a decision
  someone has to make — either the promotion flow comes back on a surface that
  observes real state, or this criterion is explicitly retired. Writing the
  spec to match today's behaviour would bury that.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A story that clears QA rides to UAT" do
    scenario "QA passes, and the next work is the UAT deploy" do
      given_ "a story whose QA has passed", context do
        # Recorded through the QA surface rather than asserted, because
        # `qa_complete` is satisfied by a DB-backed pass attempt and nothing
        # else — a story that merely says it passed does not clear the gate the
        # criterion starts from.
        # Linked to a component, because a story with none instantiates no
        # requirement graph at all and the question has nowhere to land.
        component =
          CodeMySpecSpex.ComponentHelpers.create(context.scope,
            type: "context",
            module_name: "Story841.RidesToUat",
            name: "Story841 Rides To Uat"
          )

        story =
          CodeMySpecSpex.Fixtures.story_fixture(context.scope, %{
            title: "Story 841 rides to UAT",
            component_id: component.id,
            # Released for development, which is the pace gate: a parked story
            # produces no requirement nodes at all, so the graph came back
            # 0/0 and the question "what is next after QA" had nowhere to
            # land. A story that has cleared QA was necessarily released.
            ready_for_dev: true
          })

        CodeMySpecSpex.Fixtures.passed_qa_attempt(context.scope, story_id: story.id)

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the loop asks what is outstanding on that story", context do
        # The story's own chain rather than `get_next_requirement`. Global
        # priority answers "what should anyone do next on this project", which
        # in a fresh fixture is project setup — true, and not what this
        # criterion is about. The claim is about what comes after QA *on this
        # story*.
        {:reply, response, _frame} =
          ShowStoryRequirements.execute(
            %{story: to_string(context.story.id)},
            %Frame{assigns: %{current_scope: context.scope}}
          )

        {:ok, Map.put(context, :next, response_text(response))}
      end

      then_ "it is the UAT deploy", context do
        assert context.next =~ "deploy",
               "expected the deploy to be the next work after QA cleared, got: #{context.next}"

        # Case-insensitive: the environment is named `uat` and the node
        # describes it as "UAT". Same environment, and the criterion is about
        # which one, not how it is spelled.
        assert context.next =~ ~r/uat/i,
               "expected UAT specifically — prod promotion belongs to the release process"

        {:ok, context}
      end

      then_ "prod promotion is not offered here", context do
        refute context.next =~ ~r/promote.*prod/i,
               "expected promotion to belong to the release process, not to the deploy step"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
