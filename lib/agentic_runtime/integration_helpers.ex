defmodule AgenticRuntime.IntegrationHelpers do
  @moduledoc """
  Reusable helpers for agent event handling and state management in
  Phoenix Channel handlers.

  This module is **channel-based**, not LiveView-based. State lives in the
  channel `Phoenix.Socket.assigns`, and `:messages` is a plain list — the
  caller is responsible for pushing UI events to the client when assigns
  change. Helpers never call `put_flash`; they log errors and let the caller
  decide what to relay.

  ## State Management Helpers

  - `init_agent_state/1` - Initialize all agent assigns to defaults
  - `load_conversation/3` - Load conversation and set up complete agent state
  - `reset_conversation/1` - Reset all agent state to defaults

  ## Event Handlers

  Helpers for translating agent PubSub events into socket-assign updates:

  - Status change handlers (running, idle, cancelled, error) — `:interrupted` DISABLED (plan: valiant-twirling-crown)
  - Message handlers (LLM deltas, message complete, display messages)
  - Tool execution handlers (identified, executing, completed)
  - Lifecycle handlers (title generated, agent shutdown)
  - HITL approval / rejection (`handle_hitl_decision/3`) — DISABLED (plan: valiant-twirling-crown)
  - AskUserQuestion responses (`handle_question_response/2`) — DISABLED (plan: valiant-twirling-crown)

  By default these helpers talk to `AgenticRuntime.Conversations` and
  `AgenticRuntime.Agents.Coordinator`. Pass `:conversations_module` to
  `load_conversation/3` if you wrap the context.
  """

  import Phoenix.Socket, only: [assign: 3]

  alias AgenticRuntime.Conversations
  alias AgenticRuntime.Agents.Coordinator
  alias AgenticRuntime.Agents.ServerAdapter
  alias LangChain.MessageDelta
  alias LangChain.Message.ToolCall

  require Logger

  # === STATE MANAGEMENT HELPERS ===

  @doc """
  Initialize all agent-related assigns to their default empty state.

  ## Assigns Set

  - `:conversation` - nil
  - `:conversation_id` - nil
  - `:agent_id` - nil
  - `:agent_status` - :not_running
  - `:todos` - []
  - `:has_messages` - false
  - `:streaming_delta` - nil
  - `:loading` - false
  - `:pending_tools` - [] (DISABLED — plan: valiant-twirling-crown)
  - `:pending_question` - nil (DISABLED — plan: valiant-twirling-crown)
  - `:remaining_questions` - [] (DISABLED — plan: valiant-twirling-crown)
  - `:question_responses` - [] (DISABLED — plan: valiant-twirling-crown)
  - `:interrupt_data` - nil (DISABLED — plan: valiant-twirling-crown)
  - `:hitl_decisions` - [] (DISABLED — plan: valiant-twirling-crown)
  - `:messages` - []
  """
  def init_agent_state(socket) do
    socket
    |> assign(:conversation, nil)
    |> assign(:conversation_id, nil)
    |> assign(:agent_id, nil)
    |> assign(:agent_status, :not_running)
    |> assign(:todos, [])
    |> assign(:has_messages, false)
    |> assign(:streaming_delta, nil)
    |> assign(:loading, false)
    # DISABLED (plan: valiant-twirling-crown): assigns dead after middleware removal
    # |> assign(:pending_tools, [])
    # |> assign(:pending_question, nil)
    # |> assign(:remaining_questions, [])
    # |> assign(:question_responses, [])
    # |> assign(:interrupt_data, nil)
    # |> assign(:hitl_decisions, [])
    |> assign(:messages, [])
  end

  @doc """
  Load a conversation from the database and set up all agent-related state.

  ## Parameters

  - `socket` - The channel socket
  - `conversation_id` - ID of the conversation to load
  - `opts`:
    - `:scope` (required) - Host scope (anything implementing `AgenticRuntime.Scope`)
    - `:user_id` (optional) - User ID for presence tracking
    - `:conversations_module` (optional) - Module to use for DB operations
      (default: `AgenticRuntime.Conversations`)

  ## Returns

  - `{:ok, socket}` - Socket with conversation loaded and all agent state set
  - `{:error, :not_found, socket}` - Conversation not found; assigns unchanged

  Callers translate the error tuple into whatever channel reply they prefer.
  """
  def load_conversation(socket, conversation_id, opts) do
    scope = Keyword.fetch!(opts, :scope)
    # DISABLED (plan: presence-shutdown-removal): :user_id no longer consumed —
    # presence-based shutdown was removed. Accepted-but-ignored for callers that
    # haven't been updated yet.
    _user_id = Keyword.get(opts, :user_id)
    conversations = Keyword.get(opts, :conversations_module, Conversations)

    try do
      socket = maybe_unsubscribe_previous(socket, conversation_id)

      conversation = conversations.get_conversation!(scope, conversation_id)
      agent_id = Coordinator.conversation_agent_id(conversation_id)

      socket = subscribe_and_track(socket, conversation_id)

      display_messages = conversations.load_display_messages(scope, conversation_id)
      has_messages = !Enum.empty?(display_messages)
      saved_todos = conversations.load_todos(scope, conversation_id)

      agent_status = ServerAdapter.get_status(agent_id)

      socket =
        socket
        |> assign(:conversation, conversation)
        |> assign(:conversation_id, conversation_id)
        |> assign(:agent_id, agent_id)
        |> assign(:todos, saved_todos)
        |> assign(:agent_status, agent_status)
        |> assign(:messages, display_messages)
        |> assign(:has_messages, has_messages)

      # DISABLED (plan: valiant-twirling-crown): no middleware can fire :interrupted
      # after FileSystem + HITL + AskUserQuestion removal; restore branch is dead.
      # # Restore HITL state if agent is interrupted (e.g. after channel reconnect)
      # socket =
      #   if agent_status == :interrupted do
      #     info = ServerAdapter.impl().get_info(agent_id)
      #     handle_status_interrupted(socket, info.interrupt_data)
      #   else
      #     socket
      #   end

      {:ok, socket}
    rescue
      Ecto.NoResultsError ->
        {:error, :not_found, socket}
    end
  end

  @doc """
  Reset all agent-related state to default values and clean up subscriptions.
  """
  def reset_conversation(socket) do
    if socket.assigns[:conversation_id] do
      :ok = Coordinator.unsubscribe_from_conversation(socket.assigns.conversation_id)
      Logger.debug("Unsubscribed from conversation #{socket.assigns.conversation_id}")
    end

    init_agent_state(socket)
  end

  # === PRIVATE HELPERS FOR STATE MANAGEMENT ===

  defp maybe_unsubscribe_previous(socket, conversation_id) do
    if socket.assigns[:conversation_id] &&
         socket.assigns.conversation_id != conversation_id do
      :ok = Coordinator.unsubscribe_from_conversation(socket.assigns.conversation_id)
      Logger.debug("Unsubscribed from previous conversation #{socket.assigns.conversation_id}")
    end

    socket
  end

  defp subscribe_and_track(socket, conversation_id, _user_id \\ nil) do
    :ok = Coordinator.ensure_subscribed_to_conversation(conversation_id)

    # DISABLED (plan: presence-shutdown-removal): track_conversation_viewer call
    # removed — presence-based shutdown is off. Restore by re-adding the track call
    # and threading user_id back through load_conversation/3.
    #   if user_id do
    #     case Coordinator.track_conversation_viewer(conversation_id, user_id) do
    #       {:ok, _ref} ->
    #         :ok
    #
    #       {:error, {:already_tracked, _, _, _}} ->
    #         :ok
    #
    #       {:error, reason} ->
    #         Logger.warning("Failed to track presence: #{inspect(reason)}")
    #         :ok
    #     end
    #   end
    socket
  end

  # === STATUS CHANGE HANDLERS ===

  @doc "Handles agent status change to :running."
  def handle_status_running(socket) do
    assign(socket, :agent_status, :running)
  end

  @doc "Handles agent status change to :idle (execution completed successfully)."
  def handle_status_idle(socket) do
    socket
    |> assign(:loading, false)
    |> assign(:agent_status, :idle)
    |> assign(:streaming_delta, nil)
  end

  @doc """
  Handles agent status change to :cancelled (user cancelled execution).

  The cancellation message is persisted by AgentServer and arrives via
  `{:display_message_saved, ...}`. This handler just updates UI state.
  """
  def handle_status_cancelled(socket) do
    socket
    |> assign(:loading, false)
    |> assign(:agent_status, :cancelled)
    |> assign(:streaming_delta, nil)
  end

  @doc """
  Handles agent status change to :error (execution failed).

  Logs the error and updates state. The caller should push the error to the
  client (the formatted message is also returned in `:last_error_message`).
  """
  def handle_status_error(socket, reason) do
    error_text = format_error_message(reason)
    Logger.error("Agent error: #{error_text}")

    socket
    |> assign(:loading, false)
    |> assign(:agent_status, :error)
    |> assign(:streaming_delta, nil)
    |> assign(:last_error_message, error_text)
  end

  # DISABLED (plan: valiant-twirling-crown): no middleware can fire :interrupted
  # after FileSystem + HITL + AskUserQuestion removal. Function fully commented;
  # only caller (load_conversation/3 interrupt branch) is also commented.
  # @doc """
  # Handles agent status change to :interrupted.
  #
  # DISABLED (plan: valiant-twirling-crown): with FileSystem + HITL + AskUserQuestion
  # middleware all removed from the stack, no middleware can fire `:interrupted`.
  # Stubbed to just record the status; no interrupt-type dispatch.
  # """
  # def handle_status_interrupted(socket, interrupt_data) do
  #   socket
  #   |> assign(:loading, false)
  #   |> assign(:agent_status, :interrupted)
  #   |> assign(:interrupt_data, interrupt_data)
  # end

  # DISABLED (plan: valiant-twirling-crown): interrupt-type dispatch helpers
  # defp apply_interrupt_assigns(socket, %{type: :ask_user_question} = question) do
  #   present_questions(socket, [question])
  # end
  #
  # defp apply_interrupt_assigns(socket, %{type: :multiple_interrupts, interrupts: interrupts}) do
  #   if Enum.all?(interrupts, &(&1.type == :ask_user_question)) do
  #     present_questions(socket, interrupts)
  #   else
  #     present_hitl_tools(socket, interrupts)
  #   end
  # end
  #
  # defp apply_interrupt_assigns(socket, interrupt_data) do
  #   present_hitl_tools(socket, interrupt_data)
  # end
  #
  # defp present_questions(socket, [first | rest]) do
  #   socket
  #   |> assign(:pending_question, first)
  #   |> assign(:remaining_questions, rest)
  #   |> assign(:question_responses, [])
  #   |> assign(:pending_tools, [])
  # end
  #
  # defp present_hitl_tools(socket, interrupt_data) do
  #   socket
  #   |> assign(:pending_tools, extract_action_requests(interrupt_data))
  #   |> assign(:pending_question, nil)
  # end
  #
  # # Sub-agent HITL: action_requests are nested inside interrupt_data.interrupt_data
  # defp extract_action_requests(%{type: :subagent_hitl, interrupt_data: inner}) do
  #   Map.get(inner, :action_requests, [])
  # end
  #
  # defp extract_action_requests(interrupt_data) do
  #   Map.get(interrupt_data, :action_requests, [])
  # end

  # === MESSAGING HANDLERS ===

  @doc "Handles streaming LLM deltas (incremental response chunks)."
  def handle_llm_deltas(socket, deltas) do
    update_streaming_message(socket, deltas)
  end

  @doc """
  Handles complete LLM message received.

  Persisted display messages (from `:display_message_saved`) are now the
  authoritative display, so the streaming delta is cleared.
  """
  def handle_llm_message_complete(socket) do
    socket
    |> assign(:streaming_delta, nil)
    |> assign(:loading, false)
  end

  @doc """
  Handles single display message saved to database.

  Reloads messages from the database when a scope is available so the
  authoritative ordering is preserved; otherwise just appends the message
  to `:messages`.
  """
  def handle_display_message_saved(socket, display_msg) do
    socket =
      if socket.assigns[:conversation_id] && socket.assigns[:current_scope] do
        socket
        |> assign(:streaming_delta, nil)
        |> reload_messages_from_db()
      else
        assign(socket, :messages, (socket.assigns[:messages] || []) ++ [display_msg])
      end

    assign(socket, :has_messages, true)
  end

  # === TOOL EXECUTION HANDLERS ===

  @doc """
  Handles tool call identified event.

  Sets display_text directly on the matching ToolCall in the streaming delta
  and tracks the tool's execution status.
  """
  def handle_tool_call_identified(socket, tool_info) do
    current_delta = socket.assigns[:streaming_delta]

    updated_delta =
      if current_delta do
        current_delta
        |> set_tool_display_text(tool_info.name, tool_info[:display_text])
        |> set_tool_execution_status(tool_info.name, "identified")
      else
        # Non-streaming or delta not yet received — create minimal delta
        tc = %ToolCall{
          name: tool_info.name,
          call_id: tool_info[:call_id],
          display_text: tool_info[:display_text],
          status: :incomplete,
          metadata: %{"execution_status" => "identified"}
        }

        %MessageDelta{role: :assistant, status: :incomplete, tool_calls: [tc]}
      end

    assign(socket, :streaming_delta, updated_delta)
  end

  @doc """
  Handles consolidated tool execution update event.

  Updates streaming delta with tool execution status. No database calls —
  persistence is handled by AgentServer via DisplayMessagePersistence.
  """
  def handle_tool_execution_update(socket, status, tool_info) do
    current_delta = socket.assigns[:streaming_delta]

    updated_delta =
      case {current_delta, status} do
        {nil, _} ->
          nil

        {delta, :executing} ->
          delta
          |> set_tool_display_text(tool_info.name, tool_info[:display_text])
          |> set_tool_execution_status(tool_info.name, "executing")

        {_delta, _completed_or_failed} ->
          # Tool finished — clear the streaming delta
          nil
      end

    assign(socket, :streaming_delta, updated_delta)
  end

  @doc """
  Handles display message updated event (from persistence layer).

  Replaces the matching message in `:messages` (matched on `:id`).
  """
  def handle_display_message_updated(socket, updated_msg) do
    messages = socket.assigns[:messages] || []

    new_messages =
      Enum.map(messages, fn m ->
        if m.id == updated_msg.id, do: updated_msg, else: m
      end)

    assign(socket, :messages, new_messages)
  end

  # === LIFECYCLE HANDLERS ===

  @doc """
  Handles conversation title generated event.

  Updates conversation title in the database. Page title and conversation
  list updates are left to the calling channel.
  """
  def handle_conversation_title_generated(socket, new_title, agent_id) do
    if agent_id == socket.assigns[:agent_id] && socket.assigns[:conversation] do
      case Conversations.update_conversation(socket.assigns.conversation, %{title: new_title}) do
        {:ok, updated_conversation} ->
          assign(socket, :conversation, updated_conversation)

        {:error, reason} ->
          Logger.error("Failed to update conversation title: #{inspect(reason)}")
          socket
      end
    else
      socket
    end
  end

  @doc """
  Handles agent shutdown event.

  Clears agent_id from assigns. The next interaction will restart the agent
  via Coordinator.
  """
  def handle_agent_shutdown(socket, shutdown_data) do
    Logger.info("Agent #{socket.assigns[:agent_id]} shutting down: #{shutdown_data.reason}")
    assign(socket, :agent_id, nil)
  end

  # === CORE HELPER FUNCTIONS ===

  @doc """
  Accumulates streaming deltas into the current streaming message.
  """
  def update_streaming_message(socket, deltas) do
    current_delta = socket.assigns[:streaming_delta]
    updated_delta = MessageDelta.merge_deltas(current_delta, deltas)

    assign(socket, :streaming_delta, updated_delta)
  end

  @doc """
  Reloads display messages from the database and updates `:messages`.
  """
  def reload_messages_from_db(socket) do
    if socket.assigns[:conversation_id] && socket.assigns[:current_scope] do
      messages =
        Conversations.load_display_messages(
          socket.assigns.current_scope,
          socket.assigns.conversation_id
        )

      assign(socket, :messages, messages)
    else
      socket
    end
  end

  @doc """
  Creates a message in database if conversation exists, otherwise creates
  in-memory fallback.

  Returns the message map (not the socket).
  """
  def create_or_persist_message(socket, message_type, text) do
    if socket.assigns[:conversation_id] && socket.assigns[:current_scope] do
      case Conversations.append_text_message(
             socket.assigns.current_scope,
             socket.assigns.conversation_id,
             message_type,
             text
           ) do
        {:ok, display_msg} ->
          display_msg

        {:error, reason} ->
          Logger.error("Failed to persist #{message_type} message: #{inspect(reason)}")
          create_fallback_message(message_type, text)
      end
    else
      create_fallback_message(message_type, text)
    end
  end

  # === HITL DECISION HANDLERS ===
  # DISABLED (plan: valiant-twirling-crown): HumanInTheLoop middleware removed from factory.
  # Entire section commented out; channel has no UI to drive these handlers.

  # @doc """
  # Handles a single HITL approve/reject decision.
  #
  # Accumulates decisions and only resumes the agent once all pending tools are
  # decided. Returns `{:ok, socket}` or `{:error, reason, socket}` so the caller
  # can push the relevant event to the client.
  # """
  # def handle_hitl_decision(socket, index, decision_type) do
  #   agent_id = socket.assigns[:agent_id]
  #
  #   if is_nil(agent_id) do
  #     Logger.error("Cannot process HITL decision: agent_id is nil (agent may have shut down)")
  #     {:error, :agent_not_running, socket}
  #   else
  #     handle_hitl_decision_impl(socket, agent_id, index, decision_type)
  #   end
  # end
  #
  # defp handle_hitl_decision_impl(socket, agent_id, index, decision_type) do
  #   pending_tools = socket.assigns.pending_tools
  #   decision_label = if decision_type == :approve, do: "approved", else: "rejected"
  #
  #   persist_hitl_decision(socket, pending_tools, index, decision_label)
  #
  #   Logger.info("#{String.capitalize(decision_label)} tool at index #{index}")
  #
  #   accumulated = (socket.assigns[:hitl_decisions] || []) ++ [%{type: decision_type}]
  #   remaining_tools = List.delete_at(pending_tools, index)
  #
  #   if remaining_tools == [] do
  #     case ServerAdapter.impl().resume(agent_id, accumulated) do
  #       :ok ->
  #         socket =
  #           socket
  #           |> assign(:agent_status, :running)
  #           |> assign(:loading, true)
  #           |> assign(:pending_tools, [])
  #           |> assign(:interrupt_data, nil)
  #           |> assign(:hitl_decisions, [])
  #
  #         {:ok, socket}
  #
  #       {:error, reason} ->
  #         Logger.error("Failed to resume agent: #{inspect(reason)}")
  #         {:error, {:resume_failed, reason}, socket}
  #     end
  #   else
  #     socket =
  #       socket
  #       |> assign(:pending_tools, remaining_tools)
  #       |> assign(:hitl_decisions, accumulated)
  #
  #     {:ok, socket}
  #   end
  # end
  #
  # # Persist HITL decision on the correct tool call display message.
  # # For sub-agent HITL, the action_request's tool_call_id belongs to the sub-agent's
  # # inner tool call, not the parent's "task" tool call. Use the parent's tool_call_id
  # # from the top-level interrupt_data instead.
  # defp persist_hitl_decision(socket, pending_tools, index, decision) do
  #   interrupt_data = socket.assigns[:interrupt_data]
  #   tool = Enum.at(pending_tools, index)
  #
  #   call_id =
  #     case interrupt_data do
  #       %{type: :subagent_hitl, tool_call_id: parent_call_id} -> parent_call_id
  #       _ -> tool[:tool_call_id]
  #     end
  #
  #   if call_id && socket.assigns[:current_scope] do
  #     Conversations.record_hitl_decision(
  #       socket.assigns.current_scope,
  #       call_id,
  #       decision
  #     )
  #   end
  # end

  # === ASK USER QUESTION HANDLERS ===
  # DISABLED (plan: valiant-twirling-crown): AskUserQuestion middleware removed from factory.
  # Channel has no handle_in for question responses, so this is dead code.

  # @doc """
  # Handles a single question response, accumulating answers for multi-question interrupts.
  #
  # When all pending questions are answered, resumes the agent with all responses.
  # Returns `{:ok, socket}` or `{:error, reason, socket}` so the caller can push
  # the relevant event to the client.
  #
  # ## Parameters
  #
  # - `socket` - The channel socket
  # - `response` - A map with `:type` (`:answer` or `:cancel`) and response data.
  #   `:tool_call_id` is set automatically from the current pending question.
  # """
  # def handle_question_response(socket, response) do
  #   agent_id = socket.assigns[:agent_id]
  #
  #   if is_nil(agent_id) do
  #     Logger.error("Cannot process question response: agent_id is nil (agent may have shut down)")
  #     {:error, :agent_not_running, socket}
  #   else
  #     current_question = socket.assigns.pending_question
  #     response = Map.put(response, :tool_call_id, current_question.tool_call_id)
  #
  #     accumulated = (socket.assigns[:question_responses] || []) ++ [response]
  #     remaining = socket.assigns[:remaining_questions] || []
  #
  #     case remaining do
  #       [] ->
  #         # All questions answered — resume the agent.
  #         # Single question: send as-is. Multiple: send the list.
  #         resume_data = if length(accumulated) == 1, do: hd(accumulated), else: accumulated
  #
  #         case ServerAdapter.impl().resume(agent_id, resume_data) do
  #           :ok ->
  #             socket =
  #               socket
  #               |> assign(:agent_status, :running)
  #               |> assign(:loading, true)
  #               |> assign(:pending_question, nil)
  #               |> assign(:remaining_questions, [])
  #               |> assign(:question_responses, [])
  #               |> assign(:interrupt_data, nil)
  #
  #             {:ok, socket}
  #
  #           {:error, reason} ->
  #             Logger.error("Failed to resume agent with question response: #{inspect(reason)}")
  #             {:error, {:resume_failed, reason}, socket}
  #         end
  #
  #       [next | rest] ->
  #         socket =
  #           socket
  #           |> assign(:pending_question, next)
  #           |> assign(:remaining_questions, rest)
  #           |> assign(:question_responses, accumulated)
  #
  #         {:ok, socket}
  #     end
  #   end
  # end

  # === PRIVATE HELPERS ===

  defp create_fallback_message(message_type, text) do
    %{
      id: generate_id(),
      message_type: message_type,
      content_type: "text",
      content: %{"text" => text},
      timestamp: DateTime.utc_now()
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp format_error_message(reason) do
    error_display =
      case reason do
        %LangChain.LangChainError{} = error -> error.message
        other -> inspect(other)
      end

    "Sorry, I encountered an error: #{error_display}"
  end

  # Set display_text on matching ToolCall(s) in a delta's tool_calls list.
  # Only updates tool calls that don't already have display_text set.
  defp set_tool_display_text(delta, tool_name, display_text) do
    updated_tool_calls =
      Enum.map(delta.tool_calls || [], fn tc ->
        if tc.name == tool_name && tc.display_text == nil do
          %{tc | display_text: display_text}
        else
          tc
        end
      end)

    %{delta | tool_calls: updated_tool_calls}
  end

  # Set execution_status on matching ToolCall(s) in a delta's tool_calls list.
  defp set_tool_execution_status(delta, tool_name, status) do
    updated_tool_calls =
      Enum.map(delta.tool_calls || [], fn tc ->
        if tc.name == tool_name do
          ToolCall.set_execution_status(tc, status)
        else
          tc
        end
      end)

    %{delta | tool_calls: updated_tool_calls}
  end
end
