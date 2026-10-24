defmodule CodeMySpecSpex.Story1063.Criterion3232Spex do
  @moduledoc """
  A publication stamp invalidates the affected story's cached verdict even
  when no checkout file or preview-health value changes.
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

  spex "Publication moves the affected story's graph", criterion: 1208 do
    scenario "one story is published without changing checkout files" do
      given_ "two unpublished stories and a graph served from a checkout", context do
        story =
          CodeMySpecSpex.StoryHelpers.create_story(context.scope,
            title: "Published work",
            description: "Certified work reaching the development branch"
          )

        other =
          CodeMySpecSpex.StoryHelpers.create_story(context.scope,
            title: "Other work",
            description: "Work not included in this publication"
          )

        reply = join_working_copy(context, "/tmp/spex-3232", "source copy")
        :ok = CodeMySpecSpex.Fixtures.record_preview_status(reply.working_copy_id, "down")
        _cold = read_graph(context, reply.working_copy_id)

        {:ok,
         Map.merge(context, %{
           working_copy_id: reply.working_copy_id,
           new_story: story,
           other_story: other,
           before: read_graph(context, reply.working_copy_id)
         })}
      end

      when_ "the publication records its named story's stamp", context do
        {:ok, _} =
          Fixtures.record_story_publication(context.scope, context.new_story.id, "certified-head",
            commit: "certified-head",
            working_copy_id: context.working_copy_id
          )

        {:ok, context}
      end

      then_ "the cached unpublished verdict changes only for the published story", context do
        after_publication = read_graph(context, context.working_copy_id)

        assert satisfaction_of(context.before, "story_promoted", :story, context.new_story.id) ==
                 false

        assert satisfaction_of(after_publication, "story_promoted", :story, context.new_story.id) ==
                 true

        assert reason_for(after_publication, "story_promoted", :story, context.new_story.id) =~
                 "certified-head"

        assert satisfaction_of(
                 after_publication,
                 "story_promoted",
                 :story,
                 context.other_story.id
               ) == false

        assert reason_for(after_publication, "story_promoted", :story, context.other_story.id) ==
                 reason_for(context.before, "story_promoted", :story, context.other_story.id)

        {:ok, context}
      end
    end
  end
end
