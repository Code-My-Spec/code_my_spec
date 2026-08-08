defmodule CodeMySpecSpex.Story987.Criterion8193Spex do
  @moduledoc """
  Story 987 — Harness-to-Server Projection
  Criterion 8193 — A spex file naming a story that does not exist is linked to
  nothing.

  Covers Rule "A file belongs to the story or component the server currently
  knows about, not the one the harness cached when it joined."

  The guard this protects was blamed for a bug it did not cause. Refusing to
  link a file to an unknown story is correct — a stale directory name must not
  invent a link, and a renamed or deleted story must not keep collecting files.
  What was wrong was the *cache* being empty, not the rule.

  Written so nobody "fixes" the rule while fixing the cache.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A spec naming a story the project does not have owns nothing" do
    scenario "the file is stored, and satisfies no requirement" do
      given_ "a spex directory named for a story id the project does not have", context do
        :ok =
          Environments.write_file(
            context.environment,
            "test/spex/99999999_a_story_that_never_existed/criterion_1_something_spex.exs",
            "defmodule Ghost do\nend\n"
          )

        {:ok, context}
      end

      when_ "the harness delivers a manifest containing it", context do
        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "no requirement is satisfied by it", context do
        refute Fixtures.requirement_satisfied?(
                 context.scope,
                 "bdd_specs_exist",
                 :story,
                 99_999_999
               ),
               """
               A directory name is not evidence that a story exists. Linking on
               the filename alone would let a stale or renamed directory satisfy
               requirements for a story nobody is working on.
               """

        {:ok, context}
      end
    end
  end
end
