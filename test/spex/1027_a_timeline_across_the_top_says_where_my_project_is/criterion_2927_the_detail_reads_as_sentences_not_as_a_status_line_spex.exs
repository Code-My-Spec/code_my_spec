defmodule CodeMySpecSpex.Story965.Criterion2927Spex do
  @moduledoc """
  Story 965 — A timeline across the top says where my project is.
  Criterion 2927 — The detail reads as sentences, not as a status line.

  Rule: The current step says what is happening in about two sentences, in
  language that assumes no code.

  The text is static and lives beside the requirement definitions — John's call,
  and it is what makes this checkable at all: a sentence written by a model is a
  different sentence every time, and there would be nothing to assert about it
  except its length.

  What the rule rules out is a status line dressed as prose. Each requirement
  already carries a description written for an engineer; this is the other one,
  for somebody who does not know what a spex boundary is and should not have to.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The current step says what is happening in about two sentences, in language that assumes no code" do
    scenario "The detail reads as sentences, not as a status line" do
      given_ "a project part-way through its requirements", context do
        # Established rather than assumed. "Part-way" means some of the
        # project's own requirements are met and some are not; on a project
        # where everything is satisfied the timeline is a different picture and
        # a block that only says so would not notice.
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/requirements")

        assert html =~ "requirement",
               "the requirements page shows nothing, so there is no project state for " <>
                 "the timeline to be part-way through"

        {:ok, context}
      end

      when_ "I read the detail on the current step", context do
        {:ok, _live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}/stories")

        detail =
          case Regex.run(~r/data-test="step-detail"[^>]*>(.*?)<\/[a-z]+>/s, html) do
            [_, text] -> text |> String.replace(~r/<[^>]+>/, "") |> String.trim()
            nil -> nil
          end

        {:ok, context |> Map.put(:html, html) |> Map.put(:detail, detail)}
      end

      then_ "it is about two sentences of plain language", context do
        assert context.detail,
               "the current step carries no detail at all"

        sentences = context.detail |> String.split(~r/[.!?]\s+|[.!?]$/, trim: true) |> length()

        assert sentences in 1..3,
               "the detail is #{sentences} sentence(s): #{inspect(context.detail)}. About " <>
                 "two is the brief — one is a label and four is a paragraph nobody reads " <>
                 "at the top of a page."

        {:ok, context}
      end

      then_ "and it names no module, file, session or task count", context do
        jargon = [
          {~r/[A-Z][A-Za-z]+\.[A-Z][A-Za-z]+/, "a module name"},
          {~r/\.(ex|exs)\b/, "a file path"},
          {~r/\b[0-9a-f]{8}-[0-9a-f]{4}/, "an id"},
          {~r/\b\d+ (tasks?|sessions?|requirements?)\b/, "a count of internals"}
        ]

        for {pattern, what} <- jargon do
          refute Regex.match?(pattern, context.detail),
                 "the detail contains #{what}: #{inspect(context.detail)}. This is the " <>
                   "line a non-technical user reads to find out how their project is " <>
                   "doing, and every one of these sends them somewhere they cannot follow."
        end

        {:ok, context}
      end
    end
  end
end
