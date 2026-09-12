defmodule CodeMySpec.McpServers.BddRules.Tools.ResolveQuestionTest do
  use ExUnit.Case, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.BddRules.Tools.ResolveQuestion
  alias CodeMySpec.Questions
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "records the resolution alongside the status" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      {:ok, question} = Questions.create_question(scope, story.id, %{text: "What counts as busy?"})
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               ResolveQuestion.execute(
                 %{question_id: question.id, resolution: "A copy whose agents died reads busy forever."},
                 frame
               )

      content = response_text(response)
      assert content =~ "Answer: A copy whose agents died reads busy forever."

      reloaded = Questions.get_question(scope, question.id)
      assert reloaded.status == :resolved
      assert reloaded.resolution == "A copy whose agents died reads busy forever."
    end

    test "resolving without a resolution leaves the record answerless, same as before" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      {:ok, question} = Questions.create_question(scope, story.id, %{text: "Does this block?"})
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               ResolveQuestion.execute(%{question_id: question.id}, frame)

      content = response_text(response)
      refute content =~ "Answer:"

      reloaded = Questions.get_question(scope, question.id)
      assert reloaded.status == :resolved
      assert reloaded.resolution == nil
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
