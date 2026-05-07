defmodule AgenticRuntime.Agents.DisplayMessagePersistence do
  @moduledoc """
  Implements `Sagents.DisplayMessagePersistence` for display messages.

  Persists user-facing message representations to PostgreSQL and handles
  tool execution lifecycle status updates. Called from within the AgentServer
  process for exactly-once semantics.
  """

  @behaviour Sagents.DisplayMessagePersistence

  require Logger

  alias Sagents.Message.DisplayHelpers
  alias LangChain.Message

  @impl true
  def save_message(conversation_id, %Message{} = message) do
    display_items = DisplayHelpers.extract_display_items(message)

    # @nelson
    # Debug: Log the message being saved
    if message.role == :assistant && message.tool_calls && length(message.tool_calls) > 0 do
      Logger.info("Saving message with #{length(message.tool_calls)} tool calls")
      Enum.each(message.tool_calls, fn tc ->
        Logger.info("  Tool call: call_id=#{tc.call_id}, name=#{tc.name}")
      end)
    end

    # Debug: Log extracted display items
    tool_call_items = Enum.filter(display_items, fn item -> item.type == :tool_call end)
    if length(tool_call_items) > 0 do
      Logger.info("Extracted #{length(tool_call_items)} tool call display items")
      Enum.each(tool_call_items, fn item ->
        Logger.info("  Display item: call_id=#{item.content["call_id"]}, name=#{item.content["name"]}")
      end)
    end

    # @nelson

    if Enum.empty?(display_items) do
      {:ok, []}
    else
      Enum.reduce_while(display_items, {:ok, []}, fn item, {:ok, acc} ->
        attrs = %{
          "message_type" => Atom.to_string(item.message_type),
          "content_type" => Atom.to_string(item.type),
          "content" => item.content
        }

        # Set status to "pending" for tool calls
        attrs =
          if item.type == :tool_call do
            Map.put(attrs, "status", "pending")
          else
            attrs
          end

        case AgenticRuntime.Conversations.append_display_message(conversation_id, attrs) do
          {:ok, display_msg} ->
            {:cont, {:ok, acc ++ [display_msg]}}

          {:error, %Ecto.Changeset{errors: errors} = changeset} ->
            # @nelson
            # Check if this is a duplicate tool call error - if so, skip it (idempotent)
            is_duplicate_tool_call =
              attrs["content_type"] == "tool_call" &&
              Enum.any?(errors, fn {field, {msg, opts}} ->
                field == :conversation_id &&
                msg == "tool call already exists for this conversation" &&
                Keyword.get(opts, :constraint) == :unique
              end)

            if is_duplicate_tool_call do
              Logger.warning(
                "Skipping duplicate tool call: call_id=#{attrs["content"]["call_id"]}, name=#{attrs["content"]["name"]}"
              )
              # Continue with existing accumulated results (idempotent behavior)
              {:cont, {:ok, acc}}
            else
              Logger.error(
                "Failed to persist DisplayMessage (#{attrs["content_type"]}): #{inspect(changeset)}"
              )

              # Debug: Log what we tried to insert
              if attrs["content_type"] == "tool_call" do
                Logger.error("  Attempted to insert: call_id=#{attrs["content"]["call_id"]}, name=#{attrs["content"]["name"]}")
              end

              {:halt, {:error, changeset}}
            end
            # @nelson
        end
      end)
    end
  end

  @impl true
  def update_tool_status(:executing, %{call_id: call_id}) do
    AgenticRuntime.Conversations.mark_tool_executing(call_id)
  end

  def update_tool_status(:completed, %{call_id: call_id, result: result} = tool_info) do
    metadata = %{"result" => result}

    metadata =
      case Map.get(tool_info, :display_text) do
        nil -> metadata
        text -> Map.put(metadata, "display_text", text)
      end

    AgenticRuntime.Conversations.complete_tool_call(call_id, metadata)
  end

  def update_tool_status(:failed, %{call_id: call_id, error: error}) do
    AgenticRuntime.Conversations.fail_tool_call(call_id, %{"error" => error})
  end

  def update_tool_status(:interrupted, %{call_id: call_id, display_text: display_text}) do
    AgenticRuntime.Conversations.interrupt_tool_call(call_id, %{"display_text" => display_text})
  end

  @doc """
  Resolves an interrupted tool result display message with the actual result content.
  Called after a sub-agent resumes and completes.
  """
  @impl true
  def resolve_tool_result(tool_call_id, result_content) do
    AgenticRuntime.Conversations.resolve_interrupted_tool_result(tool_call_id, result_content)
  end
end
