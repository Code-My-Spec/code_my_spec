defmodule CodeMySpec.Issues.Tools.GetIssueTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary
  import CodeMySpec.UsersFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.StoriesFixtures

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "returns issue detail" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope, %{title: "My Bug", severity: :high, description: "It broke"})

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "get_issue",
          %{issue_id: issue.id},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      content = response_text(response)
      assert content =~ "My Bug"
      assert content =~ "high"
      assert content =~ "It broke"
    end

    test "names the QA attempt that returned a submitted fix to awaiting submission" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      issue = issue_fixture(scope, %{status: :accepted, story_id: story.id})

      # The state `StorySubmissions.rework/5` leaves behind once a story QA
      # attempt reviews and returns this fix — written directly, the same
      # way other fixtures set up state a full submit+review cycle would
      # otherwise need a real team/working-copy assignment to reach.
      issue =
        issue
        |> Ecto.Changeset.change(
          story_submission_ref: nil,
          story_submission_history: [
            %{
              "returned_ref" => Ecto.UUID.generate(),
              "reason" => "Story QA 92b1c4de: partial",
              "returned_at" => DateTime.to_iso8601(DateTime.utc_now())
            }
          ]
        )
        |> CodeMySpec.Repo.update!()

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "get_issue",
          %{issue_id: issue.id},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      content = response_text(response)
      assert content =~ "awaiting submission"
      assert content =~ "Story QA 92b1c4de: partial"
    end

    test "returns error when not found" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "get_issue",
          %{issue_id: "00000000-0000-0000-0000-000000000000"},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
    end
  end

  defp response_text({_status, text}), do: text
end
