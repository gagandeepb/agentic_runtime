defmodule AgenticRuntime.Agents.DisplayMessagePersistence do
  @moduledoc """
  Implements `Sagents.DisplayMessagePersistence` for display messages.

  Persists user-facing message representations to PostgreSQL and handles
  tool execution lifecycle status updates. Called from within the AgentServer
  process for exactly-once semantics. Scope is threaded as the first positional
  argument by sagents.
  """

  @behaviour Sagents.DisplayMessagePersistence

  require Logger

  alias AgenticRuntime.Conversations
  alias Sagents.Message.DisplayHelpers
  alias LangChain.Message

  @impl true
  def save_message(scope, %Message{} = message, context) do
    display_items = DisplayHelpers.extract_display_items(message)

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

        case Conversations.append_display_message(scope, context.conversation_id, attrs) do
          {:ok, display_msg} ->
            {:cont, {:ok, acc ++ [display_msg]}}

          # It can happen that a display item that a tool call display item is attempted to be inserted multiple times
          # (e.g., due to agent restarts and re-emission of the same tool call)
          # further verification is needed that halting the reduction is the right choice here

          # {:error, %Ecto.Changeset{errors: errors} = changeset} ->
          #   # Tolerate the unique-tool-call-per-conversation constraint:
          #   # a duplicate insert means the tool call was already persisted (e.g.,
          #   # the agent restarted mid-stream and re-emitted the same call_id),
          #   # so we skip it and keep going.
          #   if duplicate_tool_call?(attrs, errors) do
          #     Logger.warning(
          #       "Skipping duplicate tool call: call_id=#{attrs["content"]["call_id"]}, name=#{attrs["content"]["name"]}"
          #     )

          #     {:cont, {:ok, acc}}
          #   else
          #     Logger.error(
          #       "Failed to persist DisplayMessage (#{attrs["content_type"]}): #{inspect(changeset)}"
          #     )

          #     {:halt, {:error, changeset}}
          #   end

          {:error, reason} ->
            Logger.error(
              "Failed to persist DisplayMessage (#{attrs["content_type"]}): #{inspect(reason)}"
            )

            {:halt, {:error, reason}}
        end
      end)
    end
  end

  @impl true
  def update_tool_status(scope, :executing, %{call_id: call_id}, _context) do
    Conversations.mark_tool_executing(scope, call_id)
  end

  def update_tool_status(
        scope,
        :completed,
        %{call_id: call_id, result: result} = tool_info,
        _context
      ) do
    metadata = %{"result" => result}

    metadata =
      case Map.get(tool_info, :display_text) do
        nil -> metadata
        text -> Map.put(metadata, "display_text", text)
      end

    Conversations.complete_tool_call(scope, call_id, metadata)
  end

  def update_tool_status(scope, :failed, %{call_id: call_id, error: error}, _context) do
    Conversations.fail_tool_call(scope, call_id, %{"error" => error})
  end

  def update_tool_status(
        scope,
        :interrupted,
        %{call_id: call_id, display_text: display_text},
        _context
      ) do
    Conversations.interrupt_tool_call(scope, call_id, %{"display_text" => display_text})
  end

  def update_tool_status(scope, :cancelled, %{call_id: call_id}, _context) do
    Conversations.cancel_tool_call(scope, call_id)
  end

  @impl true
  def resolve_tool_result(scope, tool_call_id, result_content, _context) do
    Conversations.resolve_interrupted_tool_result(scope, tool_call_id, result_content)
  end

  # defp duplicate_tool_call?(%{"content_type" => "tool_call"}, errors) do
  #   Enum.any?(errors, fn {field, {msg, opts}} ->
  #     field == :conversation_id &&
  #       msg == "tool call already exists for this conversation" &&
  #       Keyword.get(opts, :constraint) == :unique
  #   end)
  # end

  # defp duplicate_tool_call?(_attrs, _errors), do: false
end
