defmodule CodeMySpec.StaticAnalysis.CredoRunTest do
  @moduledoc """
  Finding credo's JSON in everything else credo printed.

  This is a parsing test with a real cause behind it. On a project whose build
  emits compiler warnings, the analyzer reported "credo produced output that is
  not JSON" and 598 genuine issues went unreported — which reads as credo being
  broken rather than as the harness failing to read it.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.StaticAnalysis.CredoRun

  # Trimmed from the real output. The brace that matters is the one in
  # `{{:., _, [erl_mod, fun]}, meta, _args}` — Elixir source quoted inside a
  # compiler warning, 330 bytes before the document actually starts.
  @warning """
      warning: this clause in cond will never match:

          {{:., _, [erl_mod, fun]}, meta, _args} = ast

      since it has type:

          false

      └─ lib/thing.ex:12: Some.Check.traverse/2

  """

  @document ~s({\n  "issues": [\n    {"message": "one", "line_no": 1},\n    {"message": "two", "line_no": 2}\n  ]\n}\n)

  describe "extract_json/1" do
    test "finds the document behind a warning that quotes braces" do
      assert {:ok, %{"issues" => issues}} = CredoRun.extract_json(@warning <> @document)

      assert length(issues) == 2,
             "the first `{` in this output belongs to an AST in a warning, not to credo"
    end

    test "the first-brace slice this replaced does not" do
      output = @warning <> @document
      {start, _} = :binary.match(output, "{")
      sliced = binary_part(output, start, byte_size(output) - start)

      assert {:error, _} = Jason.decode(sliced),
             "if this ever passes, the fixture stopped reproducing the bug"
    end

    test "output with no document at all is an error, not an empty sweep" do
      assert :error = CredoRun.extract_json(~s(** \(Mix\) The task "credo" could not be found))

      assert :error = CredoRun.extract_json(@warning),
             "a warning alone must not read as a clean run — that is the whole hazard"
    end

    test "a document with no issues key is not accepted as a clean run" do
      assert :error = CredoRun.extract_json(~s({"something_else": true})),
             "a stray object inside a warning would otherwise pass for credo's answer"
    end

    test "plain output with no preamble still works" do
      assert {:ok, %{"issues" => [_, _]}} = CredoRun.extract_json(@document)
    end

    test "an empty run is a document with an empty list, and reads as clean" do
      assert {:ok, %{"issues" => []}} = CredoRun.extract_json(@warning <> ~s({"issues": []}))
    end
  end
end
