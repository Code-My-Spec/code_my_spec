defmodule CodeMySpec.Qa.EvidenceTest do
  @moduledoc """
  One evidence file's own shape — the changeset every file
  `EvidenceUpload.collect/4` finds a home for has to pass.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Qa.Evidence

  describe "changeset/2" do
    test "accepts a fully-formed entry" do
      attrs = %{
        name: "screenshot.png",
        s3_key: "qa/11111111-1111-1111-1111-111111111111/attempt-1/screenshot.png",
        content_type: "image/png",
        bytes: 1024
      }

      changeset = Evidence.changeset(%Evidence{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).name == "screenshot.png"
    end

    test "requires every field" do
      changeset = Evidence.changeset(%Evidence{}, %{})

      refute changeset.valid?

      for field <- [:name, :s3_key, :content_type, :bytes] do
        assert field in Keyword.keys(changeset.errors),
               "expected #{field} to be required"
      end
    end
  end
end
