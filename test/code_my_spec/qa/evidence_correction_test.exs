defmodule CodeMySpec.Qa.EvidenceCorrectionTest do
  @moduledoc "Correcting evidence must retain a valid verdict and an audit trail."
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{QaFixtures, StoriesFixtures, UsersFixtures}

  alias CodeMySpec.Qa
  alias CodeMySpec.Qa.QaAttempts
  alias CodeMySpec.ToolLibrary

  test "remove_qa_evidence removes only named files and records who, when, and why" do
    scope = full_scope_fixture()
    other = full_scope_fixture()
    story = story_fixture(scope)
    {:ok, attempt} = passed_qa_attempt(scope, story_id: story.id)

    attempt =
      QaAttempts.attach_evidence(attempt, [
        %{name: "wrong.png", s3_key: "qa/p/a/wrong.png", content_type: "image/png", bytes: 3},
        %{name: "right.png", s3_key: "qa/p/a/right.png", content_type: "image/png", bytes: 4}
      ])

    attrs = %{attempt_id: attempt.id, filenames: ["wrong.png"], reason: "from an older story"}
    assert {:error, _} = ToolLibrary.run("remove_qa_evidence", attrs, %{scope: other})
    assert {:ok, text} = ToolLibrary.run("remove_qa_evidence", attrs, %{scope: scope})
    assert text =~ "removed: wrong.png"

    corrected = QaAttempts.get(scope, attempt.id)
    assert corrected.status == :pass
    assert Enum.map(corrected.evidence, & &1.name) == ["right.png"]

    assert [%{"removed" => ["wrong.png"], "reason" => "from an older story", "at" => at}] =
             corrected.evidence_corrections

    assert {:ok, _, _} = DateTime.from_iso8601(at)
    assert corrected.scenarios == attempt.scenarios

    assert {:error, _} = ToolLibrary.run("remove_qa_evidence", attrs, %{scope: scope})

    assert [%{"removed" => ["wrong.png"]}] =
             QaAttempts.get(scope, attempt.id).evidence_corrections
  end
end
