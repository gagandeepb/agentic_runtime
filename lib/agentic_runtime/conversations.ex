defmodule AgenticRuntime.Conversations do
  @moduledoc """
  Context for conversation persistence with multi-content type support.

  This module provides scoped access to conversations, agent states, and display
  messages.

  ## Scope-Based Security

  Every public function takes a scope as its first argument. Scopes are opaque to
  the library — host applications must implement the `AgenticRuntime.Scope`
  protocol on their own scope struct so this module can derive the owner id.

  Wrong-scope callers receive `{:error, :not_found}` for tenant-isolated reads
  and writes.

  ## Repo Configuration

  The Ecto repo is resolved at runtime via `Application.get_env(:agentic_runtime, :repo)`.
  Configure it in your host app:

      config :agentic_runtime, repo: MyApp.Repo

  ## Multi-Content Type Support

  Display messages support multiple content types (text, thinking, images, files, etc.).
  All content keys are strings (not atoms) due to JSONB storage.
  """

  import Ecto.Query, warn: false
  alias Sagents.Todo
  alias AgenticRuntime.Conversations.AgentState
  alias AgenticRuntime.Conversations.Conversation
  alias AgenticRuntime.Conversations.DisplayMessage
  alias AgenticRuntime.Scope

  #
  # Conversation CRUD
  #

  @doc """
  Creates a conversation within the given scope.

  The conversation is automatically associated with the scope's owner.
  Accepts attrs with either atom or string keys.
  """
  def create_conversation(scope, attrs) do
    scope
    |> Scope.owner_id()
    |> Conversation.create_changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Gets a conversation by ID, scoped to the given context.

  Raises if the conversation doesn't exist or doesn't belong to the scope.
  """
  def get_conversation!(scope, id) do
    Conversation
    |> scope_query(scope)
    |> repo().get!(id)
  end

  @doc """
  Gets a conversation by ID, scoped to the given context.

  Returns `{:ok, conversation}` or `{:error, :not_found}`.
  """
  def get_conversation(scope, id) do
    Conversation
    |> scope_query(scope)
    |> repo().get(id)
    |> case do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  @doc """
  Lists all conversations accessible within the given scope.

  ## Options

    * `:limit` - Maximum number of conversations to return (default: 50)
    * `:offset` - Number of conversations to skip (default: 0)
  """
  def list_conversations(scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    Conversation
    |> scope_query(scope)
    |> order_by([c], desc: c.updated_at)
    |> limit(^limit)
    |> offset(^offset)
    |> repo().all()
  end

  def update_conversation(%Conversation{} = conversation, attrs) do
    conversation
    |> Conversation.changeset(attrs)
    |> repo().update()
  end

  def delete_conversation(%Conversation{} = conversation) do
    repo().delete(conversation)
  end

  def delete_conversation(scope, conversation_id) when is_binary(conversation_id) do
    conversation = get_conversation!(scope, conversation_id)
    repo().delete(conversation)
  end

  #
  # Agent State Persistence
  #

  @doc """
  Saves (upsert) the serialized agent state for a conversation.

  Verifies the conversation belongs to `scope` before writing. Returns
  `{:error, :not_found}` if the conversation doesn't belong to the caller.
  """
  def save_agent_state(scope, conversation_id, state) do
    with :ok <- authorize_conversation(scope, conversation_id) do
      attrs = %{
        conversation_id: conversation_id,
        state_data: state,
        version: state["version"] || 1
      }

      case get_agent_state(scope, conversation_id) do
        nil ->
          %AgentState{}
          |> AgentState.changeset(attrs)
          |> repo().insert()

        existing ->
          existing
          |> AgentState.changeset(attrs)
          |> repo().update()
      end
    end
  end

  @doc """
  Loads the serialized agent state for a conversation, filtered by scope.

  Returns `{:ok, state_data}` on success or `{:error, :not_found}` if no state
  exists or the conversation doesn't belong to the caller.
  """
  def load_agent_state(scope, conversation_id) do
    case get_agent_state(scope, conversation_id) do
      nil -> {:error, :not_found}
      state -> {:ok, state.state_data}
    end
  end

  @doc """
  Loads just the TODOs from a saved agent state, filtered by scope.

  Useful for displaying TODOs in the UI when browsing historical conversations
  without starting the agent. Returns an empty list if no state exists, no todos
  are present, or the conversation doesn't belong to the caller.
  """
  def load_todos(scope, conversation_id) do
    case load_agent_state(scope, conversation_id) do
      {:ok, %{"state" => %{"todos" => todos}}} when is_list(todos) ->
        todos
        |> Enum.map(fn todo_map ->
          case Todo.from_map(todo_map) do
            {:ok, todo} -> todo
            {:error, _} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, _} ->
        []

      {:error, :not_found} ->
        []
    end
  end

  # Scoped agent-state lookup. Joins to Conversation so we inherit the same
  # tenant filter as `scope_query/2` applies to conversations.
  defp get_agent_state(scope, conversation_id) do
    from(s in AgentState,
      join: c in Conversation,
      on: s.conversation_id == c.id,
      where: s.conversation_id == ^conversation_id
    )
    |> scope_conversation_query(scope)
    |> repo().one()
  end

  #
  # Display Messages
  #

  @doc """
  Appends a display message to a conversation, filtered by scope.

  Verifies the conversation belongs to `scope` before inserting.
  """
  def append_display_message(scope, conversation_id, attrs) do
    with :ok <- authorize_conversation(scope, conversation_id) do
      conversation_id
      |> DisplayMessage.create_changeset(attrs)
      |> repo().insert()
    end
  end

  @doc """
  Loads display messages for a conversation, ordered chronologically.

  Verifies the conversation belongs to `scope` before querying.

  ## Options

    * `:limit` - Maximum number of messages to return (default: all)
    * `:offset` - Number of messages to skip (default: 0)
  """
  def load_display_messages(scope, conversation_id, opts \\ []) do
    case authorize_conversation(scope, conversation_id) do
      :ok ->
        query =
          DisplayMessage
          |> where([m], m.conversation_id == ^conversation_id)
          |> order_by([m], asc: m.inserted_at, asc: m.sequence)

        query =
          case Keyword.get(opts, :limit) do
            nil -> query
            limit -> limit(query, ^limit)
          end

        query =
          case Keyword.get(opts, :offset) do
            nil -> query
            offset -> offset(query, ^offset)
          end

        repo().all(query)

      {:error, :not_found} ->
        []
    end
  end

  #
  # Content Type Helper Functions
  # NOTE: All helper functions create content maps with STRING keys (not atoms)
  # because Ecto :map type (JSONB) stores keys as strings
  #

  @doc """
  Appends a text message to the conversation, filtered by scope.
  """
  def append_text_message(scope, conversation_id, message_type, text) do
    append_display_message(scope, conversation_id, %{
      message_type: message_type,
      content_type: "text",
      content: %{"text" => text}
    })
  end

  #
  # Tool call lifecycle
  #

  @doc """
  Updates a pending tool call message to "executing" status, scoped.

  Joins to Conversation to enforce tenant isolation — wrong-scope callers
  receive `{:error, :not_found}`.
  """
  @spec mark_tool_executing(term() | nil, String.t()) ::
          {:ok, DisplayMessage.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def mark_tool_executing(scope, call_id) do
    call_id
    |> tool_call_query()
    |> where([m], m.status == "pending")
    |> scope_conversation_query(scope)
    |> repo().one()
    |> case do
      nil ->
        {:error, :not_found}

      message ->
        message
        |> DisplayMessage.changeset(%{"status" => "executing"})
        |> repo().update()
    end
  end

  @doc """
  Updates a tool call message to "completed" status with result metadata, scoped.
  """
  @spec complete_tool_call(term() | nil, String.t(), map()) ::
          {:ok, DisplayMessage.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def complete_tool_call(scope, call_id, result_metadata \\ %{}) do
    call_id
    |> tool_call_query()
    |> where([m], m.status in ["pending", "executing", "interrupted"])
    |> scope_conversation_query(scope)
    |> repo().one()
    |> case do
      nil ->
        {:error, :not_found}

      message ->
        updated_metadata = Map.merge(message.metadata, result_metadata)

        message
        |> DisplayMessage.changeset(%{
          "status" => "completed",
          "metadata" => updated_metadata
        })
        |> repo().update()
    end
  end

  @doc """
  Updates a tool call message to "failed" status with error information, scoped.
  """
  @spec fail_tool_call(term() | nil, String.t(), map()) ::
          {:ok, DisplayMessage.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def fail_tool_call(scope, call_id, error_info \\ %{}) do
    call_id
    |> tool_call_query()
    |> where([m], m.status in ["pending", "executing", "interrupted"])
    |> scope_conversation_query(scope)
    |> repo().one()
    |> case do
      nil ->
        {:error, :not_found}

      message ->
        updated_metadata = Map.merge(message.metadata, error_info)

        message
        |> DisplayMessage.changeset(%{
          "status" => "failed",
          "metadata" => updated_metadata
        })
        |> repo().update()
    end
  end

  @doc """
  Updates a tool call message to "interrupted" status, scoped.
  """
  @spec interrupt_tool_call(term() | nil, String.t(), map()) ::
          {:ok, DisplayMessage.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def interrupt_tool_call(scope, call_id, interrupt_info \\ %{}) do
    call_id
    |> tool_call_query()
    |> where([m], m.status in ["pending", "executing"])
    |> scope_conversation_query(scope)
    |> repo().one()
    |> case do
      nil ->
        {:error, :not_found}

      message ->
        updated_metadata = Map.merge(message.metadata, interrupt_info)

        message
        |> DisplayMessage.changeset(%{
          "status" => "interrupted",
          "metadata" => updated_metadata
        })
        |> repo().update()
    end
  end

  @doc """
  Updates a tool call message to "cancelled" status, scoped.
  """
  @spec cancel_tool_call(term() | nil, String.t()) ::
          {:ok, DisplayMessage.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def cancel_tool_call(scope, call_id) do
    call_id
    |> tool_call_query()
    |> where([m], m.status in ["pending", "executing", "interrupted"])
    |> scope_conversation_query(scope)
    |> repo().one()
    |> case do
      nil ->
        {:error, :not_found}

      message ->
        message
        |> DisplayMessage.changeset(%{"status" => "cancelled"})
        |> repo().update()
    end
  end

  @doc """
  Records an HITL decision (approved/rejected) on a tool call display message, scoped.

  Adds `"hitl_decision"` to the tool call's metadata so the UI can display a
  discreet indicator of what the user decided. The metadata persists through
  subsequent status transitions since those operations merge metadata. Also stamps
  the matching tool_result message when one exists.
  """
  @spec record_hitl_decision(term() | nil, String.t(), String.t()) ::
          {:ok, DisplayMessage.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def record_hitl_decision(scope, call_id, decision)
      when decision in ["approved", "rejected"] do
    result =
      call_id
      |> tool_call_query()
      |> scope_conversation_query(scope)
      |> repo().one()
      |> case do
        nil ->
          {:error, :not_found}

        message ->
          updated_metadata = Map.put(message.metadata, "hitl_decision", decision)

          message
          |> DisplayMessage.changeset(%{"metadata" => updated_metadata})
          |> repo().update()
      end

    call_id
    |> tool_result_query()
    |> scope_conversation_query(scope)
    |> repo().one()
    |> case do
      nil ->
        :ok

      tr_msg ->
        updated_content = Map.put(tr_msg.content, "hitl_decision", decision)

        tr_msg
        |> DisplayMessage.changeset(%{"content" => updated_content})
        |> repo().update()
    end

    result
  end

  @doc """
  Resolves an interrupted tool result display message after a sub-agent resumes, scoped.
  """
  @spec resolve_interrupted_tool_result(term() | nil, String.t(), String.t()) ::
          {:ok, DisplayMessage.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def resolve_interrupted_tool_result(scope, tool_call_id, result_content) do
    tool_call_id
    |> tool_result_query()
    |> where([m, _c], fragment("(?->>'is_interrupt')::boolean = true", m.content))
    |> scope_conversation_query(scope)
    |> repo().one()
    |> case do
      nil ->
        {:error, :not_found}

      message ->
        updated_content =
          message.content
          |> Map.put("is_interrupt", false)
          |> Map.put("content", result_content)

        message
        |> DisplayMessage.changeset(%{"content" => updated_content})
        |> repo().update()
    end
  end

  @doc """
  Searches message content across all types, within the scope's conversations.
  """
  def search_messages(scope, search_term) do
    owner_id = Scope.owner_id(scope)

    from(m in DisplayMessage,
      join: c in Conversation,
      on: m.conversation_id == c.id,
      where: c.user_id == ^owner_id,
      where: fragment("?::text ILIKE ?", m.content, ^"%#{search_term}%")
    )
    |> repo().all()
  end

  #
  # Private Helpers
  #

  # Scope the primary Conversation table by owner id from the host's scope.
  defp scope_query(query, scope) do
    owner_id = Scope.owner_id(scope)
    from(q in query, where: q.user_id == ^owner_id)
  end

  # Scope a query that has already joined to Conversation. Applies the tenant
  # filter to the joined `c` binding instead of the primary binding.
  defp scope_conversation_query(query, scope) do
    owner_id = Scope.owner_id(scope)
    from([_m, c] in query, where: c.user_id == ^owner_id)
  end

  # Base query for tool_call display messages by call_id. Callers refine with
  # their own status predicate (or none) and pipe through scope_conversation_query/2
  # to enforce tenant isolation.
  defp tool_call_query(call_id) do
    from(m in DisplayMessage,
      join: c in Conversation,
      on: m.conversation_id == c.id,
      where: fragment("?->>'call_id' = ?", m.content, ^call_id),
      where: m.content_type == "tool_call"
    )
  end

  # Base query for tool_result display messages by tool_call_id. Callers refine
  # with additional predicates (e.g. is_interrupt) and pipe through
  # scope_conversation_query/2 to enforce tenant isolation.
  defp tool_result_query(tool_call_id) do
    from(m in DisplayMessage,
      join: c in Conversation,
      on: m.conversation_id == c.id,
      where: fragment("?->>'tool_call_id' = ?", m.content, ^tool_call_id),
      where: m.content_type == "tool_result"
    )
  end

  # Authorization check: does this conversation belong to the given scope?
  # Emits `SELECT 1 ... LIMIT 1` instead of hydrating the row, since the
  # caller only needs a yes/no answer before proceeding with a write.
  defp authorize_conversation(scope, conversation_id) do
    Conversation
    |> scope_query(scope)
    |> where([c], c.id == ^conversation_id)
    |> repo().exists?()
    |> case do
      true -> :ok
      false -> {:error, :not_found}
    end
  end

  defp repo, do: Application.get_env(:agentic_runtime, :repo)
end
