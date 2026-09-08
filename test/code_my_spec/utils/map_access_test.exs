defmodule CodeMySpec.Utils.MapAccessTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Utils.MapAccess

  describe "get/3" do
    test "reads the atom key when present" do
      assert MapAccess.get(%{status: "ok"}, :status) == "ok"
    end

    test "falls back to the string key when the atom key is absent" do
      assert MapAccess.get(%{"status" => "ok"}, :status) == "ok"
    end

    test "prefers the atom key when both are present" do
      assert MapAccess.get(%{"status" => "string", status: "atom"}, :status) == "atom"
    end

    test "returns the default when neither key is present" do
      assert MapAccess.get(%{}, :status, "fallback") == "fallback"
    end

    test "defaults to nil" do
      assert MapAccess.get(%{}, :status) == nil
    end

    test "a present value of nil is not treated as absent" do
      assert MapAccess.get(%{status: nil}, :status, "fallback") == nil
    end
  end
end
