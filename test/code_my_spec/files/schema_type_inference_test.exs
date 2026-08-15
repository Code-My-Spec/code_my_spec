defmodule CodeMySpec.Files.SchemaTypeInferenceTest do
  @moduledoc """
  The one type an implementation file is allowed to claim about itself.

  `f198b227`: 59 components whose implementation is `use Ecto.Schema` were typed
  `module`, because `ComponentSync` reads type from the spec's `## Type` section
  and a spec without one falls back to the changeset default. 49 of them have no
  spec file at all, so there was nowhere to put the declaration.

  Two things follow from the mistyping, and neither is cosmetic. They get the
  module requirement graph rather than the schema one, so they are asked for the
  wrong artifacts. And `validate_dependency_graph/1` excludes schemas on both
  ends of an edge — a `belongs_to`/`has_many` pair being an Ecto association
  rather than an architectural cycle — so with both ends typed `module` the
  exclusion never fires and ordinary associations are counted as cycles.

  The rule everywhere else is that type lives in the spec, and that rule is
  intact: these assert the inference only ever fills a gap, and that an explicit
  `## Type` still wins.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Files.ComponentExtract

  describe "ecto_schema?/1" do
    test "recognises a schema" do
      assert ComponentExtract.ecto_schema?("""
             defmodule MyApp.User do
               use Ecto.Schema

               schema "users" do
               end
             end
             """)
    end

    test "recognises one that is indented inside the module" do
      assert ComponentExtract.ecto_schema?("  use Ecto.Schema")
    end

    test "does not claim an ordinary module" do
      refute ComponentExtract.ecto_schema?("""
             defmodule MyApp.Accounts do
               alias MyApp.Repo
             end
             """)
    end

    # The check is anchored to the start of a line so that a module *about*
    # schemas is not mistaken for one. `ComponentSync` and `ComponentExtract`
    # both discuss `use Ecto.Schema` in their own docs, and a context module
    # explaining its schemas is ordinary.
    test "does not claim a module that merely mentions it in prose" do
      refute ComponentExtract.ecto_schema?("""
             defmodule MyApp.Docs do
               @moduledoc "Every schema here should use Ecto.Schema."
             end
             """)
    end

    test "does not claim a lookalike" do
      refute ComponentExtract.ecto_schema?("use Ecto.SchemaHelpers")
    end

    test "survives a file scanned on Windows" do
      assert ComponentExtract.ecto_schema?("defmodule A do\r\n  use Ecto.Schema\r\nend\r\n")
    end
  end
end
