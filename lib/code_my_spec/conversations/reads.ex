defmodule CodeMySpec.Conversations.Reads do
  @moduledoc """
  Per-user read/unread state for conversations, stored server-side so it holds
  across devices.

  A conversation is unread for a user when they marked it unread, or when it
  has a message newer than their last read. Never read counts as unread once
  there is a message.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Conversations.ConversationRead
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @type state :: %{unread?: boolean(), last_message_at: DateTime.t() | nil}

  @doc """
  Marks a conversation read (`true`) or unread (`false`) for the scope's user.

  Reading stamps `last_read_at` and clears a manual unread mark.
  """
  @spec set_read(Scope.t(), Ecto.UUID.t(), boolean()) ::
          {:ok, ConversationRead.t()} | {:error, :not_found}
  def set_read(%Scope{} = scope, conversation_id, read?) when is_boolean(read?) do
    with user_id when not is_nil(user_id) <- user_id(scope),
         true <- in_account?(scope, conversation_id) do
      changes =
        if read?,
          do: [last_read_at: DateTime.utc_now(), marked_unread: false],
          else: [marked_unread: true]

      %ConversationRead{user_id: user_id, conversation_id: conversation_id}
      |> Ecto.Changeset.change(changes)
      |> Repo.insert(
        on_conflict: {:replace, Keyword.keys(changes) ++ [:updated_at]},
        conflict_target: [:user_id, :conversation_id],
        returning: true
      )
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Read state and latest message time for each of `conversation_ids`, for the
  scope's user. Ids outside the scope's account are left out.
  """
  @spec states(Scope.t(), [Ecto.UUID.t()]) :: %{Ecto.UUID.t() => state()}
  def states(_scope, []), do: %{}

  def states(%Scope{} = scope, conversation_ids) do
    case user_id(scope) do
      nil -> %{}
      user_id -> states_for(scope, user_id, conversation_ids)
    end
  end

  defp states_for(scope, user_id, conversation_ids) do
    last =
      from m in Message,
        where: m.conversation_id in ^conversation_ids,
        group_by: m.conversation_id,
        select: %{conversation_id: m.conversation_id, at: max(m.inserted_at)}

    from(c in Conversation,
      left_join: l in subquery(last),
      on: l.conversation_id == c.id,
      left_join: r in ConversationRead,
      on: r.conversation_id == c.id and r.user_id == ^user_id,
      where: c.id in ^conversation_ids and c.account_id == ^scope.active_account_id,
      select: {c.id, l.at, r.last_read_at, r.marked_unread}
    )
    |> Repo.all()
    |> Map.new(fn {id, at, read_at, marked} ->
      {id, %{unread?: unread?(at, read_at, marked), last_message_at: at}}
    end)
  end

  @doc "Whether `id` is unread in a map from `states/2`."
  @spec unread?(%{Ecto.UUID.t() => state()}, Ecto.UUID.t()) :: boolean()
  def unread?(states, id), do: match?(%{unread?: true}, Map.get(states, id))

  defp unread?(_at, _read_at, true), do: true
  defp unread?(nil, _read_at, _marked), do: false
  defp unread?(_at, nil, _marked), do: true
  defp unread?(at, read_at, _marked), do: DateTime.compare(at, read_at) == :gt

  defp in_account?(scope, conversation_id) do
    Repo.exists?(
      from c in Conversation,
        where: c.id == ^conversation_id and c.account_id == ^scope.active_account_id
    )
  end

  defp user_id(%{user: %{id: id}}) when not is_nil(id), do: id
  defp user_id(%{user_id: id}) when not is_nil(id), do: id
  defp user_id(_scope), do: nil
end
