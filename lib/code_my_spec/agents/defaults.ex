defmodule CodeMySpec.Agents.Defaults do
  @moduledoc """
  What an agent type runs on when nobody has said.

  Story 983, and the shape is John's: *"this is gonna be a fairly complex
  default because we should have them globally and per provider — for example
  we might want our QA agent to default to GLM 5.3, but then if they're
  developing locally and only have ChatGPT set up then it should be GPT 5.4."*

  So a default is not a value. It is a **preference across providers**, and
  which one applies depends on what the account actually holds a key for.

  ## Why the fallthrough matters more than the preference

  The alternative is refusing until somebody configures a type, and that is the
  worse failure: an account signs up, connects one provider, and every agent it
  starts fails on a setting screen it has never seen. `Agents`' own moduledoc
  makes the same argument about credentials — a refusal that sends someone to
  set up something is only right when there is something to set up.

  Here there is not. The account has a working provider; the only question is
  which model on it, and having an opinion is cheaper than asking.

  ## The order is a judgement, not a fact

  Cheap-for-QA and strong-for-thinking are the two axes, and they are opinions
  that will age. They are kept here, in one list per type, so that changing our
  mind is editing a list rather than hunting for a hardcoded model id — and so
  that reading it tells you what we think without running anything.
  """

  alias CodeMySpec.Agents.Agent

  # Ordered. The first entry whose provider the account has a key for wins.
  #
  # QA leads with the cheapest thing that can follow instructions, because it
  # runs constantly and reads more than it reasons. Main leads with the
  # strongest, because it is the one explaining the project to somebody who
  # cannot read the code.
  @preferences %{
    main: [
      {"anthropic", "claude-sonnet-5"},
      {"openai-codex", "gpt-5.4"},
      {"zai", "glm-5.3"}
    ],
    product: [
      {"anthropic", "claude-sonnet-5"},
      {"openai-codex", "gpt-5.4"},
      {"zai", "glm-5.3"}
    ],
    coding: [
      {"anthropic", "claude-sonnet-5"},
      {"openai-codex", "gpt-5.4"},
      {"zai", "glm-5.3"}
    ],
    qa: [
      {"zai", "glm-5.3"},
      {"openai-codex", "gpt-5.4-mini"},
      {"anthropic", "claude-haiku-4-5"}
    ]
  }

  @doc """
  The preference list for a type, most preferred first.

  Public so a settings screen can show what a type *would* do before anybody
  chooses — "unset" and "unset, and here is what that means" are different
  things to read, and only the second is true.
  """
  @spec for_role(atom()) :: [{String.t(), String.t()}]
  def for_role(role) when role in [:main, :product, :coding, :qa],
    do: Map.fetch!(@preferences, role)

  def for_role(_role), do: []

  @doc """
  The first preference whose provider is in `available`.

  `{:error, :no_provider}` when the account holds none of them — which is not
  a defaulting problem but an account with nothing connected, and says so
  rather than inventing a provider it cannot authenticate.
  """
  @spec resolve(atom(), [String.t()]) :: {:ok, {String.t(), String.t()}} | {:error, :no_provider}
  def resolve(role, available) do
    role
    |> for_role()
    |> Enum.find(fn {provider, _model} -> provider in available end)
    |> case do
      nil -> {:error, :no_provider}
      choice -> {:ok, choice}
    end
  end

  @doc "Every type that has a default, which is every type there is."
  @spec roles() :: [atom()]
  def roles, do: Agent.roles()
end
