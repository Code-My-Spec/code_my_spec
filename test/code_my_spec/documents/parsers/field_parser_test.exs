defmodule CodeMySpec.Documents.Parsers.FieldParserTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Documents.Field
  alias CodeMySpec.Documents.Parsers.FieldParser

  describe "from_ast/1" do
    test "extracts table headers from thead" do
      ast = [
        {"table", [],
         [
           {"thead", [],
            [
              {"tr", [],
               [
                 {"th", [], ["Field"], %{}},
                 {"th", [], ["Type"], %{}},
                 {"th", [], ["Required"], %{}},
                 {"th", [], ["Description"], %{}},
                 {"th", [], ["Constraints"], %{}}
               ], %{}}
            ], %{}},
           {"tbody", [],
            [
              {"tr", [],
               [
                 {"td", [], ["id"], %{}},
                 {"td", [], ["integer"], %{}},
                 {"td", [], ["Yes"], %{}},
                 {"td", [], ["Primary key"], %{}},
                 {"td", [], ["Auto-generated"], %{}}
               ], %{}}
            ], %{}}
         ], %{}}
      ]

      assert [%Field{}] = FieldParser.from_ast(ast)
    end

    test "parses each tbody row into Field struct" do
      ast = [
        {"table", [],
         [
           {"thead", [],
            [
              {"tr", [],
               [
                 {"th", [], ["Field"], %{}},
                 {"th", [], ["Type"], %{}},
                 {"th", [], ["Required"], %{}}
               ], %{}}
            ], %{}},
           {"tbody", [],
            [
              {"tr", [],
               [
                 {"td", [], ["id"], %{}},
                 {"td", [], ["integer"], %{}},
                 {"td", [], ["Yes"], %{}}
               ], %{}},
              {"tr", [],
               [
                 {"td", [], ["name"], %{}},
                 {"td", [], ["string"], %{}},
                 {"td", [], ["No"], %{}}
               ], %{}}
            ], %{}}
         ], %{}}
      ]

      fields = FieldParser.from_ast(ast)
      assert length(fields) == 2
    end

    test "maps column values to correct field attributes" do
      ast = [
        {"table", [],
         [
           {"thead", [],
            [
              {"tr", [],
               [
                 {"th", [], ["Field"], %{}},
                 {"th", [], ["Type"], %{}},
                 {"th", [], ["Required"], %{}},
                 {"th", [], ["Description"], %{}},
                 {"th", [], ["Constraints"], %{}}
               ], %{}}
            ], %{}},
           {"tbody", [],
            [
              {"tr", [],
               [
                 {"td", [], ["id"], %{}},
                 {"td", [], ["integer"], %{}},
                 {"td", [], ["Yes (auto)"], %{}},
                 {"td", [], ["Primary key"], %{}},
                 {"td", [], ["Auto-generated"], %{}}
               ], %{}}
            ], %{}}
         ], %{}}
      ]

      assert [%Field{} = field] = FieldParser.from_ast(ast)
      assert field.field == "id"
      assert field.type == "integer"
      assert field.required == "Yes (auto)"
      assert field.description == "Primary key"
      assert field.constraints == "Auto-generated"
    end

    test "handles tables with all columns" do
      ast = [
        {"table", [],
         [
           {"thead", [],
            [
              {"tr", [],
               [
                 {"th", [], ["Field"], %{}},
                 {"th", [], ["Type"], %{}},
                 {"th", [], ["Required"], %{}},
                 {"th", [], ["Description"], %{}},
                 {"th", [], ["Constraints"], %{}}
               ], %{}}
            ], %{}},
           {"tbody", [],
            [
              {"tr", [],
               [
                 {"td", [], ["name"], %{}},
                 {"td", [], ["string"], %{}},
                 {"td", [], ["Yes"], %{}},
                 {"td", [], ["User name"], %{}},
                 {"td", [], ["Min: 1, Max: 255"], %{}}
               ], %{}}
            ], %{}}
         ], %{}}
      ]

      assert [%Field{} = field] = FieldParser.from_ast(ast)
      assert field.field == "name"
      assert field.type == "string"
      assert field.required == "Yes"
      assert field.description == "User name"
      assert field.constraints == "Min: 1, Max: 255"
    end

    test "handles tables with missing optional columns" do
      ast = [
        {"table", [],
         [
           {"thead", [],
            [
              {"tr", [],
               [
                 {"th", [], ["Field"], %{}},
                 {"th", [], ["Type"], %{}},
                 {"th", [], ["Required"], %{}}
               ], %{}}
            ], %{}},
           {"tbody", [],
            [
              {"tr", [],
               [
                 {"td", [], ["id"], %{}},
                 {"td", [], ["integer"], %{}},
                 {"td", [], ["Yes"], %{}}
               ], %{}}
            ], %{}}
         ], %{}}
      ]

      assert [%Field{} = field] = FieldParser.from_ast(ast)
      assert field.field == "id"
      assert field.type == "integer"
      assert field.required == "Yes"
      assert field.description == nil
      assert field.constraints == nil
    end

    test "returns empty list for empty tbody" do
      ast = [
        {"table", [],
         [
           {"thead", [],
            [
              {"tr", [],
               [
                 {"th", [], ["Field"], %{}},
                 {"th", [], ["Type"], %{}},
                 {"th", [], ["Required"], %{}}
               ], %{}}
            ], %{}},
           {"tbody", [], [], %{}}
         ], %{}}
      ]

      assert [] = FieldParser.from_ast(ast)
    end

    test "returns empty list when no table found in AST" do
      ast = [
        {"p", [], ["Some paragraph"], %{}},
        {"h2", [], ["Section"], %{}}
      ]

      assert [] = FieldParser.from_ast(ast)
    end
  end
end
