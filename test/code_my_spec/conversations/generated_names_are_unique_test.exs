defmodule CodeMySpec.Conversations.GeneratedNamesAreUniqueTest do
  @moduledoc """
  Two conversations on one project must not answer to the same name.

  The name is how an operator tells them apart. 25 adjectives x 23 nouns is
  575 combinations, so two agents on one copy collide about one time in five
  hundred — and when they do, both rows render the same "Open <name>" link to
  two different transcripts. Criterion 2892 caught exactly that on 2026-09-20,
  and its own words are the cost: "an operator picks the wrong one and has
  redirected the agent they were not watching".

  Asserted over enough conversations that a collision is a certainty rather
  than a coin flip: 575 names cannot cover 600 rows, so any duplicate here is
  the generator repeating itself rather than bad luck.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Conversations

  test "no two conversations on one project share a generated name" do
    scope = full_scope_fixture()

    names =
      for _ <- 1..600 do
        # The session variant, because it takes an external id rather than an
        # `agent_id` foreign key — 600 real agent rows would be asserting the
        # fixture rather than the generator, and both creation sites name
        # conversations through the same `generated_name/2`.
        {:ok, conversation} =
          Conversations.find_or_create_session_conversation(
            scope.active_account_id,
            scope.active_project_id,
            "spex-name-#{System.unique_integer([:positive])}"
          )

        conversation.name
      end

    duplicates = names -- Enum.uniq(names)

    assert duplicates == [],
           """
           #{length(duplicates)} generated name(s) repeated, so two conversations
           render the same link to different transcripts.

           Repeated: #{inspect(Enum.uniq(duplicates))}
           """
  end
end
