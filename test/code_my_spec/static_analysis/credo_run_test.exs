defmodule CodeMySpec.StaticAnalysis.CredoRunTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.StaticAnalysis.CredoRun

  @warning "warning: dependency compilation printed {{:., _, [module, function]}}\n"
  @document ~s({"issues":[{"message":"one"},{"message":"two"}]})

  describe "extract_json/1" do
    test "accepts a complete Credo document" do
      assert {:ok, %{"issues" => [_, _]}} = CredoRun.extract_json(@document)
      assert {:ok, %{"issues" => []}} = CredoRun.extract_json(~s({"issues": []}))
    end

    test "retains findings when compiler warnings precede Credo JSON" do
      assert {:ok, %{"issues" => [_, _]}} = CredoRun.extract_json(@warning <> @document)
      assert {:ok, [_, _], _raw} = CredoRun.parse(@warning <> @document)
      assert {:ok, [_, _], _raw} = CredoRun.parse("21:36:49.068 [info] chatter\n" <> @document)
    end

    test "never treats an unrelated object or missing document as a clean run" do
      assert :error = CredoRun.extract_json(~s({"something_else": true}))
      assert :error = CredoRun.extract_json(@warning)
      assert :error = CredoRun.extract_json(~s{** (Mix) The task "credo" could not be found})
    end
  end

  describe "parse/1 on a stale deps/" do
    test "a mix lock refusal says to fetch deps" do
      output = """
      Unchecked dependencies for environment dev:
      * alloy (https://github.com/Code-My-Spec/alloy.git - main)
        lock mismatch: the dependency is out of date. To fetch locked version run "mix deps.get"
      ** (Mix) Can't continue due to errors on dependencies
      """

      assert {:error, reason} = CredoRun.parse(output)
      assert reason =~ "deps out of date with mix.lock; run `mix deps.get`"
      refute reason =~ "not JSON"
    end

    test "other unreadable output keeps the reason" do
      assert {:error, reason} = CredoRun.parse(~s{** (Mix) The task "credo" could not be found})
      assert reason =~ "not JSON"
      assert reason =~ "could not be found"
    end
  end
end
