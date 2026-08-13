defmodule CodeMySpecWeb.QuestionLive.Show do
  @moduledoc """
  Answer a remote `AskUserQuestion` from Claude Code on your phone. Renders each
  question with its options (single- or multi-select) plus an "Other" free-text
  choice, and posts the answers back — which the waiting hook returns to the
  model. Mirrors `PermissionLive.Show`.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Notifications
  alias CodeMySpecWeb.ChatComponents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Notifications.get_question_request(id) do
      nil ->
        {:ok, socket |> put_flash(:error, "Question not found") |> assign(request: nil)}

      request ->
        if request.user_id != socket.assigns.current_scope.user.id do
          {:ok, socket |> put_flash(:error, "Not authorized") |> assign(request: nil)}
        else
          if connected?(socket) do
            Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "question_request:#{id}")
          end

          {:ok, assign(socket, page_title: "Answer", request: request)}
        end
    end
  end

  @impl true
  def handle_event("submit", params, socket) do
    request = socket.assigns.request
    answers = collect_answers(request.questions, params)

    case Notifications.answer_question_request(request.id, answers) do
      {:ok, updated} ->
        {:noreply, socket |> assign(request: updated) |> put_flash(:info, "Answer sent")}

      {:error, {:already_resolved, _}} ->
        {:noreply,
         socket
         |> assign(request: Notifications.get_question_request(request.id))
         |> put_flash(:info, "Already answered")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:question_answered, _}, socket) do
    {:noreply,
     assign(socket, request: Notifications.get_question_request(socket.assigns.request.id))}
  end

  # Build %{question_text => answer} from the form params. A choice of "Other"
  # resolves to the matching free-text field.
  defp collect_answers(questions, params) do
    questions
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {question, i}, acc ->
      answer = resolve_answer(question, params["q_#{i}"], params["q_#{i}_other"])
      Map.put(acc, question["question"], answer)
    end)
  end

  defp resolve_answer(_question, choices, other) when is_list(choices) do
    Enum.map(choices, fn c -> if c == "__other__", do: other || "", else: c end)
  end

  defp resolve_answer(_question, "__other__", other), do: other || ""
  defp resolve_answer(_question, choice, _other) when is_binary(choice), do: choice
  defp resolve_answer(_question, _choice, _other), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_notifications={@pending_notifications}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <div class="mx-auto max-w-lg">
        <ChatComponents.question :if={@request} request={@request} />

        <div :if={!@request} class="py-12 text-center opacity-70">
          Question not found or not authorized.
        </div>
      </div>
    </Layouts.app>
    """
  end
end
