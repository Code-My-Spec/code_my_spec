defmodule CodeMySpec.StaticAnalysis.SobelowRunTest do
  @moduledoc """
  Finding sobelow's JSON in everything else sobelow printed.

  Mirrors `CredoRunTest` — same hazard, same fix (`9a78afa1`): a compiler
  warning or a stray log line ahead of the real document must not be
  mistaken for "sobelow found nothing" or "this is not sobelow's output".
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.StaticAnalysis.SobelowRun

  # Trimmed from a real compiler warning. The brace that matters is inside
  # `{{:., _, [erl_mod, fun]}, meta, _args}` — Elixir source quoted inside a
  # compiler warning, well before the document actually starts.
  @warning """
      warning: this clause in cond will never match:

          {{:., _, [erl_mod, fun]}, meta, _args} = ast

      since it has type:

          false

      └─ lib/thing.ex:12: Some.Check.traverse/2

  """

  @document ~s({\n  "findings": {\n    "high_confidence": [{"type": "SQL Injection", "file": "lib/thing.ex"}],\n    "medium_confidence": [],\n    "low_confidence": []\n  }\n}\n)

  describe "extract_json/1" do
    test "finds the document behind a warning that quotes braces" do
      assert {:ok, %{"findings" => findings}} = SobelowRun.extract_json(@warning <> @document)
      assert %{"high_confidence" => [_]} = findings
    end

    test "output with no document at all is an error, not an empty sweep" do
      assert :error =
               SobelowRun.extract_json(~s(** \(Mix\) The task "sobelow" could not be found))

      assert :error = SobelowRun.extract_json(@warning)
    end

    test "a document with no findings key is not accepted as a clean run" do
      assert :error = SobelowRun.extract_json(~s({"something_else": true})),
             "a stray object inside a warning would otherwise pass for sobelow's answer"
    end

    test "a log line written to stdout in front of the document is not a document" do
      assert :error = SobelowRun.extract_json("21:36:49.068 [info] something happened\n")

      assert {:ok, %{"findings" => %{}}} =
               SobelowRun.extract_json("21:36:49.068 [info] chatter\n" <> ~s({"findings": {}})),
             "a log line before a real document must not lose the document"
    end

    test "plain output with no preamble still works" do
      assert {:ok, %{"findings" => %{"high_confidence" => [_]}}} =
               SobelowRun.extract_json(@document)
    end

    test "an empty run is a document with empty findings, and reads as clean" do
      assert {:ok, %{"findings" => %{}}} =
               SobelowRun.extract_json(@warning <> ~s({"findings": {}}))
    end
  end

  describe "available?/1" do
    test "false when the environment has no mix.exs" do
      {:ok, env} = CodeMySpec.Environments.create(:memory, working_dir: "/memfs/no-project")
      refute SobelowRun.available?(env)
    end
  end
end
