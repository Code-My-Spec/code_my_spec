defmodule CodeMySpecWeb.QuestionLive.Show do
  @moduledoc """
  Answer a remote `AskUserQuestion` from Claude Code on your phone. Renders each
  question with its options (single- or multi-select) plus an "Other" free-text
  choice, and posts the answers back — which the waiting hook returns to the
  model. Mirrors `PermissionLive.Show`.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Notifications

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
    {:noreply, assign(socket, request: Notifications.get_question_request(socket.assigns.request.id))}
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
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-lg">
        <div :if={@request} class="card bg-base-200 shadow-xl">
          <div class="card-body">
            <h2 class="card-title text-2xl">
              <.icon name="hero-chat-bubble-left-right" class="size-6 text-primary" />
              {@request.title || "Claude Code has a question"}
            </h2>

            <div :if={@request.status == "answered"} class="mt-4">
              <div class="alert alert-success">
                <.icon name="hero-check-circle" class="size-5" /> Answer sent — you can close this.
              </div>
              <dl class="mt-4 space-y-2">
                <div :for={{q, a} <- @request.answers} class="text-sm">
                  <dt class="font-semibold opacity-70">{q}</dt>
                  <dd>{format_answer(a)}</dd>
                </div>
              </dl>
            </div>

            <form :if={@request.status == "pending"} phx-submit="submit" class="mt-4 space-y-6">
              <fieldset :for={{question, i} <- Enum.with_index(@request.questions)} class="space-y-2">
                <div>
                  <span :if={question["header"]} class="badge badge-primary badge-sm">{question["header"]}</span>
                  <p class="mt-1 font-medium">{question["question"]}</p>
                </div>

                <label
                  :for={opt <- question["options"] || []}
                  class="flex cursor-pointer items-start gap-3 rounded-box border border-base-300 p-3 hover:bg-base-300/40"
                >
                  <input
                    type={input_type(question)}
                    name={field_name(question, i)}
                    value={opt["label"]}
                    class={choice_class(question)}
                  />
                  <span class="flex flex-col">
                    <span class="font-medium">{opt["label"]}</span>
                    <span :if={opt["description"]} class="text-xs opacity-60">{opt["description"]}</span>
                  </span>
                </label>

                <label class="flex cursor-pointer items-center gap-3 rounded-box border border-dashed border-base-300 p-3">
                  <input type={input_type(question)} name={field_name(question, i)} value="__other__" class={choice_class(question)} />
                  <input
                    type="text"
                    name={"q_#{i}_other"}
                    placeholder="Other…"
                    class="input input-bordered input-sm flex-1"
                  />
                </label>
              </fieldset>

              <button type="submit" class="btn btn-primary btn-lg w-full">Send answer</button>
            </form>
          </div>
        </div>

        <div :if={!@request} class="py-12 text-center opacity-70">
          Question not found or not authorized.
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp input_type(%{"multiSelect" => true}), do: "checkbox"
  defp input_type(_question), do: "radio"

  defp field_name(%{"multiSelect" => true}, i), do: "q_#{i}[]"
  defp field_name(_question, i), do: "q_#{i}"

  defp choice_class(%{"multiSelect" => true}), do: "checkbox checkbox-primary mt-0.5"
  defp choice_class(_question), do: "radio radio-primary mt-0.5"

  defp format_answer(a) when is_list(a), do: Enum.join(a, ", ")
  defp format_answer(a), do: to_string(a)
end
