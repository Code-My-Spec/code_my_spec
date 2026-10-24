defmodule CodeMySpecSpex.Story1147.Criterion2395Spex do
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.RemotePromotionHelpers
  alias CodeMySpecSpex.{Fixtures, PromotionHelpers}
  alias Ecto.Adapters.SQL.Sandbox
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  import CodeMySpecSpex.ReadyForQaHelpers,
    only: [a_held_ready_for_qa_task: 2, complete_ready_for_qa: 1]

  spex "A test-only change retains applicable QA", criterion: 2395 do
    scenario "re-certification preserves the product-change rule" do
      given_ "a reviewed candidate followed by another commit", context do
        context = context |> remote_project() |> verified_candidate()

        PromotionHelpers.write(
          context.agent_root,
          "test/example_test.exs",
          "defmodule ExampleTest do\nend\n"
        )

        git!(context.agent_root, ["add", "test/example_test.exs"])
        git!(context.agent_root, ["commit", "-m", "after review"])
        Fixtures.fresh_analysis_runs(context.scope, ~w(compiler credo exunit spex), at_head: true)
        {:ok, a_held_ready_for_qa_task(context, context.story)}
      end

      when_ "John re-certifies and asks to promote", context do
        {error?, text} = complete_ready_for_qa(context)
        refute error?, text

        {:ok,
         Map.put(context, :response, PromotionHelpers.promote(context, context.story.number))}
      end

      then_ "the admission decision respects what QA exercised", context do
        text = CodeMySpecSpex.TaskResponseHelpers.response_text(context.response)
        refute context.response.isError, text
        assert text =~ "Queued for promotion"
        assert remote_head(context) == context.base
        {:ok, context}
      end
    end
  end
end
