defmodule CodeMySpec.Utils.StructIntrospectorTest do
  use ExUnit.Case
  doctest CodeMySpec.Utils.StructIntrospector
  alias CodeMySpec.Utils.StructIntrospector

  test "introspects ComponentDesign struct" do
    Code.ensure_loaded(CodeMySpec.ComponentDesignFixture)
    result = StructIntrospector.introspect(CodeMySpec.ComponentDesignFixture)

    assert %{
             fields: fields,
             required_fields: required
           } = result

    assert :purpose in fields
    assert :public_api in fields
    assert :execution_flow in fields
    assert :other_sections in fields

    assert :purpose in required
    assert :public_api in required
    assert :execution_flow in required
  end
end
