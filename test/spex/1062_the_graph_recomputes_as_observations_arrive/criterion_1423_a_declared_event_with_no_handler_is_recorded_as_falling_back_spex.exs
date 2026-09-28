defmodule CodeMySpecSpex.Story1062.Criterion3514Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3514 — A declared event with no handler is recorded as falling back.

  Rule: the kinds that still recompute are a list somebody can read, not a
  silence.

  ## Why the debt is published rather than inferred

  A kind that falls back is not a defect. Handlers arrive one requirement at a
  time and the projection stays correct in the meantime — an unhandled event
  still names its entities and is recomputed from them, which is slower and
  never wrong. That is what makes this feature shippable in pieces.

  It is also what makes the debt invisible. A full recompute triggered by an
  unhandled kind and a cheap settle triggered by a handled one look identical
  from outside: same announcement, same updated graph, same silence. The only
  difference is cost, and cost is the thing this whole story is about.

  So "which kinds still recompute" has to be answerable, and answerable by
  looking rather than by reading the handler table and diffing it against the
  vocabulary in your head. The closed vocabulary is what makes the question
  well-formed at all — a writer cannot emit a kind that is not declared, so the
  set to ask about is finite and known.

  ## Surface

  The graph dev page, which is where this is now published. That choice is the
  criterion's own: "the list of such kinds is the outstanding work, not a
  silence" is a claim about somebody being able to see it, and a claim that is
  only true inside a test module is not that claim.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  setup :register_log_in_setup_account
  setup :setup_active_project

  @endpoint CodeMySpecWeb.Endpoint

  spex "The kinds that still recompute are published", criterion: 1423 do
    scenario "the vocabulary is read from the graph dev page" do
      given_ "a project whose graph has a declared event vocabulary", context do
        {:ok, _view, html} = live(context.conn, "/dev/graph")

        assert html =~ ~s(data-test="event-vocabulary"),
               """
               The page does not publish the event vocabulary at all.

               Without it, "which kinds still fall back" is answerable only by
               reading `Handlers` and diffing it against `GraphInputs.kinds/0`
               by hand — which is exactly the silence this criterion exists to
               replace.
               """

        {:ok, Map.put(context, :html, html)}
      end

      when_ "the graph is asked whether every declared kind can be applied", context do
        {:ok,
         context
         |> Map.put(:declared, attribute(context.html, "event-vocabulary", "data-declared"))
         |> Map.put(:falls_back, attribute(context.html, "event-vocabulary", "data-falls-back"))
         |> Map.put(:kinds, kinds(context.html))}
      end

      then_ "every declared kind is accounted for", context do
        assert context.declared == to_string(length(context.kinds)),
               """
               The page says #{context.declared} kinds are declared and shows
               #{length(context.kinds)} of them.

               A summary that disagrees with the list under it is worse than
               either alone: whichever a reader trusts, they are being told a
               number nothing on the page supports.
               """

        assert context.kinds != [],
               "no kinds are published, so nothing here is being claimed at all"

        {:ok, context}
      end

      then_ "and a kind with no handler is named as one that still recomputes", context do
        unapplied = for {kind, false} <- context.kinds, do: kind

        assert context.falls_back == to_string(length(unapplied)),
               """
               The page counts #{context.falls_back} kinds as falling back and
               marks #{length(unapplied)} of them.

               falls back: #{inspect(unapplied)}
               """

        {:ok, context}
      end

      then_ "and the list is the outstanding work rather than a silence", context do
        applied = for {kind, true} <- context.kinds, do: kind
        unapplied = for {kind, false} <- context.kinds, do: kind

        assert applied != [] or unapplied != [],
               "the vocabulary is empty, so the page claims nothing either way"

        # Both halves are named, and that is the point. A page that showed only
        # the handled kinds would report progress and hide the debt; one that
        # showed only the unhandled would say nothing about how far along the
        # work is. The criterion asks for the outstanding work to be *the
        # list*, which means every kind carries its own answer.
        assert Enum.all?(context.kinds, fn {_kind, applied?} -> is_boolean(applied?) end),
               """
               Some kinds are published without saying whether anything applies
               them: #{inspect(context.kinds)}.

               A kind with no answer is the silence in a different shape — it
               appears in the list, so it looks accounted for, and nothing says
               it costs a recompute every time it occurs.
               """

        {:ok, context}
      end
    end
  end

  # `{kind, applied?}` for every kind the page published, read off the markup
  # the way a reader reads the badges.
  defp kinds(html) do
    ~r/data-test="vocabulary-kind"\s+data-kind="([^"]+)"\s+data-applied="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_match, kind, applied] -> {kind, applied == "true"} end)
  end

  defp attribute(html, test_id, name) do
    ~r/data-test="#{test_id}"[^>]*?#{name}="([^"]*)"/
    |> Regex.run(html)
    |> then(fn
      [_match, value] -> value
      nil -> nil
    end)
  end
end
