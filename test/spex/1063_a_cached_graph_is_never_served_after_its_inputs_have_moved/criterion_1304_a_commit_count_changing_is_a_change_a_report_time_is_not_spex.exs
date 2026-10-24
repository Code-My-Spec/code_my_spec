defmodule CodeMySpecSpex.Story1063.Criterion3339Spex do
  @moduledoc """
  A checkout heartbeat leaves the publication verdict alone; a newly recorded
  publication stamp changes it. Both observations use the same cached vantage.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The graph tells a heartbeat apart from publication", criterion: 1304 do
    scenario "a checkout reports and then its story is published" do
      given_ "an unpublished story and a graph served from a checkout", context do
        story =
          CodeMySpecSpex.StoryHelpers.create_story(context.scope,
            title: "Reported work",
            description: "Awaiting publication"
          )

        reply = join_working_copy(context, "/tmp/spex-3339", "source copy")
        :ok = CodeMySpecSpex.Fixtures.record_preview_status(reply.working_copy_id, "down")
        _cold = read_graph(context, reply.working_copy_id)

        {:ok,
         Map.merge(context, %{
           working_copy_id: reply.working_copy_id,
           new_story: story,
           before: read_graph(context, reply.working_copy_id)
         })}
      end

      when_ "it repeats its health report and then receives a publication stamp", context do
        :ok = CodeMySpecSpex.Fixtures.record_preview_status(context.working_copy_id, "down")
        after_heartbeat = read_graph(context, context.working_copy_id)

        {:ok, _} =
          Fixtures.record_story_publication(context.scope, context.new_story.id, "certified-head",
            commit: "certified-head",
            working_copy_id: context.working_copy_id
          )

        {:ok, Map.put(context, :after_heartbeat, after_heartbeat)}
      end

      then_ "the heartbeat preserves the answer and publication changes it", context do
        reason = fn graph -> reason_for(graph, "story_promoted", :story, context.new_story.id) end

        assert satisfaction_of(context.before, "story_promoted", :story, context.new_story.id) ==
                 false

        assert reason.(context.after_heartbeat) == reason.(context.before)

        assert satisfaction_of(
                 context.after_heartbeat,
                 "story_promoted",
                 :story,
                 context.new_story.id
               ) == false

        after_publication = read_graph(context, context.working_copy_id)
        refute reason.(after_publication) == reason.(context.after_heartbeat)

        assert satisfaction_of(after_publication, "story_promoted", :story, context.new_story.id) ==
                 true

        assert reason.(after_publication) =~ "certified-head"
        {:ok, context}
      end
    end
  end
end
