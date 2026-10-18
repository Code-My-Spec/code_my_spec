defmodule CodeMySpec.BddRules.Tools.ResolveQuestionTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Questions
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "records the resolution alongside the status" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, question} =
        Questions.create_question(scope, story.id, %{text: "What counts as busy?"})

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "resolve_question",
          %{question_id: question.id, resolution: "A copy whose agents died reads busy forever."},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      content = response_text(response)
      assert content =~ "Answer: A copy whose agents died reads busy forever."

      reloaded = Questions.get_question(scope, question.id)
      assert reloaded.status == :resolved
      assert reloaded.resolution == "A copy whose agents died reads busy forever."
    end

    test "an unknown id names the other tool a list_open_questions id needs" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run("resolve_question", %{question_id: Ecto.UUID.generate()}, %{
          scope: frame.assigns.current_scope
        })

      content = response_text(response)
      assert content =~ "not found in the active account"
      assert content =~ "answer_question"
    end

    test "resolving without a resolution leaves the record answerless, same as before" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      {:ok, question} = Questions.create_question(scope, story.id, %{text: "Does this block?"})
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run("resolve_question", %{question_id: question.id}, %{
          scope: frame.assigns.current_scope
        })

      content = response_text(response)
      refute content =~ "Answer:"

      reloaded = Questions.get_question(scope, question.id)
      assert reloaded.status == :resolved
      assert reloaded.resolution == nil
    end
  end

  defp response_text({_status, text}), do: text
end
