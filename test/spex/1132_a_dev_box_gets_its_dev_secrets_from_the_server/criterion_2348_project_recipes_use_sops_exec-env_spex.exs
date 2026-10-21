defmodule CodeMySpecSpex.Story1132.Criterion2348Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2348 -- Project recipes use sops exec-env.

  Reads this project's own `justfile` directly off real disk, not the
  memfs, through `Fixtures.justfile_recipe_body/1` (the spex boundary's
  escape hatch for a file no app surface serves): `just test` is a recipe
  of *this* repository, the one thing a spex here can check without
  inventing a project to generate one for. This is the project criterion
  2321 (story 1133) already names as the one that runs `just dev-setup`;
  the same recipe set is what this criterion asks to be wrapped in
  `sops exec-env`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  spex "The project's own recipes decrypt their secrets through sops exec-env",
    criterion: 2348 do
    scenario "Sam's project runs `just test`" do
      given_ "Sam's project has a `test` recipe in its justfile", context do
        {:ok, context}
      end

      when_ "the `test` recipe's body is read", context do
        {:ok, Map.put(context, :test_recipe_body, Fixtures.justfile_recipe_body("test"))}
      end

      then_ "the recipe runs the tests through sops exec-env and they get their secrets",
            context do
        assert context.test_recipe_body =~ "sops exec-env",
               "the `test` recipe does not run through sops exec-env, so a dev box with no " <>
                 "key file on disk has no way to get its secrets into `mix test` at all:\n\n" <>
                 context.test_recipe_body

        {:ok, context}
      end
    end
  end
end
