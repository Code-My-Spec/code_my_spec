defmodule CodeMySpecSpex.Story1157.Criterion2259Spex do
  @moduledoc """
  Story 1157 — A story shows what it builds on and what builds on it.
  Criterion 2259 — A dependency that would close a loop is refused.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryDependencyScript, as: Deps

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A dependency that would close a loop is refused", criterion: 2259 do
    scenario "recording the reverse of an existing dependency is refused, naming the loop" do
      given_ "story 11 builds on story 10", context do
        ten = Deps.story(context.scope, "Ten")
        eleven = Deps.story(context.scope, "Eleven")
        result = Deps.link(context.scope, eleven, ten)
        refute result.error?, "add_story_dependency failed: #{result.text}"
        {:ok, Map.merge(context, %{ten: ten, eleven: eleven})}
      end

      when_ "an agent records that story 10 builds on story 11", context do
        {:ok, Map.put(context, :result, Deps.link(context.scope, context.ten, context.eleven))}
      end

      then_ "it is refused, naming the loop 10 to 11 to 10", context do
        assert context.result.error?,
               "a dependency closing a loop was accepted: #{context.result.text}"

        assert context.result.text =~
                 ~r/#{context.ten}\D+#{context.eleven}\D+#{context.ten}/,
               "the refusal does not name the loop #{context.ten} to #{context.eleven} to " <>
                 "#{context.ten}: #{context.result.text}"

        {:ok, context}
      end
    end
  end
end
