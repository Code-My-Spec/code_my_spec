defmodule CodeMySpec.Intake.Planner.Inferred do
  @moduledoc """
  Derives a plan from the description without an LLM.

  Stands in until `req_llm` lands on main. It is deterministic and offline,
  which makes it the right implementation for tests regardless of what the
  default becomes.
  """

  @behaviour CodeMySpec.Intake.Planner

  alias CodeMySpec.Intake.Plan

  @stop_words ~w(a an and the for of to my our i we app application site website system tool that this it is are want build make)

  @impl true
  def generate(%Plan{description: description} = plan) when is_binary(description) do
    subject = subject(description)

    {:ok,
     %{
       summary: summary(plan, subject),
       first_build: first_build(subject),
       account_name: title_case(subject),
       project_name: title_case(subject)
     }}
  end

  defp summary(%Plan{} = plan, subject) do
    "You're building #{article(subject)} #{subject}#{audience(plan)}. #{sign_in(plan)} #{copies(plan)}"
  end

  defp first_build(subject) do
    "The first thing to build is the one screen that makes the #{subject} worth opening — everything else hangs off it."
  end

  defp audience(%Plan{who_uses: who}) when is_binary(who) and byte_size(who) > 0,
    do: " for #{who}"

  defp audience(_), do: ""

  defp sign_in(%Plan{needs_sign_in: true}), do: "People sign in to use it."
  defp sign_in(%Plan{needs_sign_in: false}), do: "Anyone can use it without signing in."

  defp copies(%Plan{separate_copies: true}),
    do: "Each business gets its own separate copy of the data."

  defp copies(%Plan{separate_copies: false}), do: "Everyone shares the one set of data."

  # The longest meaningful word in the description, as a rough stand-in for
  # what the thing is. An LLM will do better; this only has to be recognisable.
  defp subject(description) do
    description
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.max_by(&String.length/1, fn -> "project" end)
  end

  defp article(<<first::utf8, _rest::binary>>) when first in ~c"aeiou", do: "an"
  defp article(_), do: "a"

  defp title_case(word) do
    word |> String.split(~r/[\s-]+/, trim: true) |> Enum.map_join(" ", &String.capitalize/1)
  end
end
