defmodule CodeMySpec.DocumentsTest do
  use ExUnit.Case, async: true
  doctest CodeMySpec.Documents

  alias CodeMySpec.Documents

  # `qa_result`: required status and scenarios, optional evidence and issues,
  # nothing else allowed.
  @valid_result """
  # QA Result

  ## Status

  pass

  ## Scenarios

  ### The page loads

  It loaded.
  """

  describe "create_dynamic_document/3" do
    test "creates a document whose required sections are present" do
      assert {:ok, document} = Documents.create_dynamic_document(@valid_result, "qa_result")
      assert document.type == "qa_result"
      assert Map.has_key?(document.sections, "status")
    end

    test "returns an error naming the missing required section" do
      markdown = "# QA Result\n\n## Status\n\npass\n"

      assert {:error, error} = Documents.create_dynamic_document(markdown, "qa_result")
      assert error =~ "Missing required sections"
      assert error =~ "scenarios"
    end

    test "allows an optional section" do
      markdown = @valid_result <> "\n## Evidence\n\nA screenshot.\n"
      assert {:ok, _} = Documents.create_dynamic_document(markdown, "qa_result")
    end

    test "rejects a section the type does not allow, naming it" do
      markdown = @valid_result <> "\n## Musings\n\nUnrelated.\n"

      assert {:error, error} = Documents.create_dynamic_document(markdown, "qa_result")
      assert error =~ "musings"
    end

    test "allows any section when allowed_additional_sections is '*'" do
      markdown = "# Anything\n\n## Whatever\n\nText.\n\n## Something Else\n\nMore.\n"

      assert {:ok, document} = Documents.create_dynamic_document(markdown, "dynamic_document")
      assert Map.has_key?(document.sections, "whatever")
    end

    test "an unknown type is read as a dynamic document" do
      assert {:ok, _} = Documents.create_dynamic_document("# A\n\n## B\n\nC.\n", "no_such_type")
    end

    test "returns an error when document_type is nil" do
      assert {:error, error} = Documents.create_dynamic_document(@valid_result, nil)
      assert error =~ "Document type is required"
    end

    test "returns an error when document_type is empty" do
      assert {:error, error} = Documents.create_dynamic_document(@valid_result, "")
      assert error =~ "Document type is required"
    end

    test "normalises CRLF before validating" do
      crlf = String.replace(@valid_result, "\n", "\r\n")
      assert {:ok, _} = Documents.create_dynamic_document(crlf, "qa_result")
    end
  end
end
