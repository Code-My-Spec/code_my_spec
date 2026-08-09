defmodule CodeMySpec.Intake.Questions do
  @moduledoc """
  The shaping questions, asked one at a time.

  Two of these pick generators — sign-in selects auth, separate copies selects
  multitenancy — and getting one wrong costs the visitor the app they get. The
  third asks who uses it, which selects nothing but gives the plan language
  that sounds like the visitor's business rather than ours.

  They were a single form of three fields. A form asks everyone the same three
  questions in the same order and cannot take account of an answer, which is
  the whole reason to have a conversation instead. The wording is unchanged;
  only the delivery is.

  Order matters: sign-in first, because tenancy only makes sense once you know
  whether anyone signs in at all.
  """

  alias CodeMySpec.Intake.Plan

  @questions [
    %{
      field: :needs_sign_in,
      type: :boolean,
      text: "Will people need to sign in to use this?",
      hint: "Yes if people have their own login. No if anyone can just use it."
    },
    %{
      field: :separate_copies,
      type: :boolean,
      text: "Will lots of separate businesses each use their own copy?",
      hint: "No if this is just for one business — yours."
    },
    %{
      field: :who_uses,
      type: :text,
      text: "Roughly who uses this?",
      hint: "A few words is plenty."
    }
  ]

  @doc "Every question, in the order they are asked."
  @spec all() :: [map()]
  def all, do: @questions

  @doc "How many questions a visitor can be asked before the plan."
  @spec count() :: pos_integer()
  def count, do: length(@questions)

  @doc """
  The question still owed, or nil when the visitor has answered them all.

  Read off the plan rather than counted, so a visitor who reloads mid-way is
  asked what is still missing instead of starting again.
  """
  @spec next(Plan.t()) :: map() | nil
  def next(%Plan{} = plan) do
    Enum.find(@questions, &is_nil(Map.fetch!(plan, &1.field)))
  end

  @doc "How many have been answered, for showing progress through a short conversation."
  @spec answered_count(Plan.t()) :: non_neg_integer()
  def answered_count(%Plan{} = plan) do
    Enum.count(@questions, &(not is_nil(Map.fetch!(plan, &1.field))))
  end

  @doc """
  Casts a written answer for a question into the value its field holds.

  Booleans accept what someone actually types at a question ending in a
  question mark, not just "true".
  """
  @spec cast_answer(map(), String.t()) :: {:ok, term()} | :error
  def cast_answer(%{type: :boolean}, answer) do
    case answer |> to_string() |> String.trim() |> String.downcase() do
      yes when yes in ~w(yes y true yep yeah sure they do) -> {:ok, true}
      no when no in ~w(no n false nope nah) -> {:ok, false}
      _ -> :error
    end
  end

  def cast_answer(%{type: :text}, answer) do
    case answer |> to_string() |> String.trim() do
      "" -> :error
      text -> {:ok, text}
    end
  end
end
