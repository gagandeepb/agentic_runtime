defmodule AgenticRuntime.IntegrationHelpersTest do
  use AgenticRuntime.DataCase, async: true

  import Mox

  alias AgenticRuntime.Agents.ServerAdapter
  alias AgenticRuntime.IntegrationHelpers

  setup :verify_on_exit!

  defp socket(assigns \\ %{}) do
    %Phoenix.Socket{assigns: assigns}
  end

  describe "init_agent_state/1" do
    test "sets every agent assign to its documented default" do
      result = IntegrationHelpers.init_agent_state(socket())

      assert result.assigns.conversation == nil
      assert result.assigns.conversation_id == nil
      assert result.assigns.agent_id == nil
      assert result.assigns.agent_status == :not_running
      assert result.assigns.todos == []
      assert result.assigns.has_messages == false
      assert result.assigns.streaming_delta == nil
      assert result.assigns.loading == false
      assert result.assigns.pending_tools == []
      assert result.assigns.pending_question == nil
      assert result.assigns.remaining_questions == []
      assert result.assigns.question_responses == []
      assert result.assigns.interrupt_data == nil
      assert result.assigns.hitl_decisions == []
      assert result.assigns.messages == []
    end
  end

  describe "status handlers" do
    test "handle_status_running sets :running" do
      assert IntegrationHelpers.handle_status_running(socket()).assigns.agent_status == :running
    end

    test "handle_status_idle clears loading + delta" do
      result =
        socket(%{loading: true, streaming_delta: %{}, agent_status: :running})
        |> IntegrationHelpers.handle_status_idle()

      assert result.assigns.agent_status == :idle
      assert result.assigns.loading == false
      assert result.assigns.streaming_delta == nil
    end

    test "handle_status_cancelled clears in-flight state" do
      result =
        socket(%{loading: true, streaming_delta: %{}, agent_status: :running})
        |> IntegrationHelpers.handle_status_cancelled()

      assert result.assigns.agent_status == :cancelled
      assert result.assigns.loading == false
      assert result.assigns.streaming_delta == nil
    end

    test "handle_status_error stores formatted error message" do
      reason = %LangChain.LangChainError{message: "rate limited", type: :api_error}

      result =
        socket(%{loading: true, streaming_delta: %{}})
        |> IntegrationHelpers.handle_status_error(reason)

      assert result.assigns.agent_status == :error
      assert result.assigns.loading == false
      assert result.assigns.last_error_message =~ "rate limited"
    end

    test "handle_status_interrupted with ask_user_question presents the question" do
      interrupt = %{
        type: :ask_user_question,
        tool_call_id: "q1",
        question: "Pick one"
      }

      result =
        socket(%{loading: true})
        |> IntegrationHelpers.handle_status_interrupted(interrupt)

      assert result.assigns.agent_status == :interrupted
      assert result.assigns.pending_question == interrupt
      assert result.assigns.remaining_questions == []
      assert result.assigns.pending_tools == []
      assert result.assigns.loading == false
    end

    test "handle_status_interrupted with multi-question interrupt queues remaining" do
      q1 = %{type: :ask_user_question, tool_call_id: "q1", question: "first?"}
      q2 = %{type: :ask_user_question, tool_call_id: "q2", question: "second?"}
      interrupt = %{type: :multiple_interrupts, interrupts: [q1, q2]}

      result =
        socket()
        |> IntegrationHelpers.handle_status_interrupted(interrupt)

      assert result.assigns.pending_question == q1
      assert result.assigns.remaining_questions == [q2]
    end

    test "handle_status_interrupted with HITL interrupt presents pending tools" do
      interrupt = %{
        action_requests: [%{tool_call_id: "t1", name: "delete"}]
      }

      result =
        socket()
        |> IntegrationHelpers.handle_status_interrupted(interrupt)

      assert result.assigns.pending_tools == [%{tool_call_id: "t1", name: "delete"}]
      assert result.assigns.pending_question == nil
    end
  end

  describe "LLM streaming + completion" do
    test "handle_llm_message_complete clears the streaming delta and stops loading" do
      result =
        socket(%{streaming_delta: %{some: "delta"}, loading: true})
        |> IntegrationHelpers.handle_llm_message_complete()

      assert result.assigns.streaming_delta == nil
      assert result.assigns.loading == false
    end

    test "handle_llm_deltas accumulates into the streaming delta" do
      delta1 = %LangChain.MessageDelta{role: :assistant, content: "hello", status: :incomplete}
      delta2 = %LangChain.MessageDelta{role: :assistant, content: " world", status: :incomplete}

      result =
        socket()
        |> IntegrationHelpers.handle_llm_deltas([delta1])
        |> IntegrationHelpers.handle_llm_deltas([delta2])

      assert [%LangChain.Message.ContentPart{content: "hello world"}] =
               result.assigns.streaming_delta.merged_content
    end
  end

  describe "tool execution updates" do
    test "handle_tool_execution_update with completed clears the streaming delta" do
      delta = %LangChain.MessageDelta{role: :assistant, status: :incomplete, tool_calls: []}

      result =
        socket(%{streaming_delta: delta})
        |> IntegrationHelpers.handle_tool_execution_update(:completed, %{name: "search"})

      assert result.assigns.streaming_delta == nil
    end

    test "handle_tool_execution_update with no streaming delta is a no-op" do
      result =
        socket()
        |> IntegrationHelpers.handle_tool_execution_update(:executing, %{name: "search"})

      assert result.assigns.streaming_delta == nil
    end
  end

  describe "handle_display_message_updated/2" do
    test "replaces the matching message by id" do
      m1 = %{id: "1", message_type: "user", content: %{"text" => "old"}}
      m2 = %{id: "2", message_type: "assistant", content: %{"text" => "ans"}}

      result =
        socket(%{messages: [m1, m2]})
        |> IntegrationHelpers.handle_display_message_updated(%{m1 | content: %{"text" => "new"}})

      [first, second] = result.assigns.messages
      assert first.content["text"] == "new"
      assert second == m2
    end
  end

  describe "handle_hitl_decision/3" do
    test "errors when no agent is running" do
      result =
        socket(%{agent_id: nil, pending_tools: [%{tool_call_id: "x"}]})
        |> IntegrationHelpers.handle_hitl_decision(0, :approve)

      assert {:error, :agent_not_running, _} = result
    end

    test "accumulates decision when more pending tools remain" do
      pending = [
        %{tool_call_id: "t1", name: "a"},
        %{tool_call_id: "t2", name: "b"}
      ]

      socket =
        socket(%{
          agent_id: "agent-1",
          pending_tools: pending,
          hitl_decisions: [],
          interrupt_data: nil
        })

      assert {:ok, updated} = IntegrationHelpers.handle_hitl_decision(socket, 0, :approve)

      assert length(updated.assigns.pending_tools) == 1
      assert updated.assigns.hitl_decisions == [%{type: :approve}]
    end

    test "resumes the agent when the last decision arrives" do
      pending = [%{tool_call_id: "only", name: "delete"}]

      socket =
        socket(%{
          agent_id: "agent-1",
          pending_tools: pending,
          hitl_decisions: [],
          interrupt_data: %{}
        })

      expect(ServerAdapter.Mock, :resume, fn "agent-1", [%{type: :reject}] -> :ok end)

      assert {:ok, result} = IntegrationHelpers.handle_hitl_decision(socket, 0, :reject)
      assert result.assigns.agent_status == :running
      assert result.assigns.loading == true
      assert result.assigns.pending_tools == []
      assert result.assigns.interrupt_data == nil
      assert result.assigns.hitl_decisions == []
    end

    test "propagates resume failure as {:error, ...}" do
      pending = [%{tool_call_id: "only"}]

      socket =
        socket(%{
          agent_id: "agent-1",
          pending_tools: pending,
          hitl_decisions: [],
          interrupt_data: %{}
        })

      expect(ServerAdapter.Mock, :resume, fn _, _ -> {:error, :boom} end)

      assert {:error, {:resume_failed, :boom}, _} =
               IntegrationHelpers.handle_hitl_decision(socket, 0, :approve)
    end
  end

  describe "handle_question_response/2" do
    test "errors when no agent is running" do
      result =
        socket(%{agent_id: nil, pending_question: %{tool_call_id: "q"}})
        |> IntegrationHelpers.handle_question_response(%{type: :answer, value: "yes"})

      assert {:error, :agent_not_running, _} = result
    end

    test "accumulates answers and presents the next question" do
      q1 = %{tool_call_id: "q1", question: "first?"}
      q2 = %{tool_call_id: "q2", question: "second?"}

      socket =
        socket(%{
          agent_id: "agent-1",
          pending_question: q1,
          remaining_questions: [q2],
          question_responses: []
        })

      assert {:ok, updated} =
               IntegrationHelpers.handle_question_response(socket, %{type: :answer, value: "yes"})

      assert updated.assigns.pending_question == q2
      assert updated.assigns.remaining_questions == []
      assert [%{type: :answer, value: "yes", tool_call_id: "q1"}] = updated.assigns.question_responses
    end

    test "resumes with single answer when only one question was asked" do
      q1 = %{tool_call_id: "q1", question: "first?"}

      socket =
        socket(%{
          agent_id: "agent-1",
          pending_question: q1,
          remaining_questions: [],
          question_responses: []
        })

      expect(ServerAdapter.Mock, :resume, fn "agent-1", %{type: :answer, tool_call_id: "q1"} ->
        :ok
      end)

      assert {:ok, updated} =
               IntegrationHelpers.handle_question_response(socket, %{type: :answer, value: "ok"})

      assert updated.assigns.pending_question == nil
      assert updated.assigns.question_responses == []
      assert updated.assigns.agent_status == :running
    end

    test "resumes with list of answers for multi-question interrupts" do
      q1 = %{tool_call_id: "q1", question: "first?"}

      socket =
        socket(%{
          agent_id: "agent-1",
          pending_question: q1,
          remaining_questions: [],
          question_responses: [%{type: :answer, value: "prev", tool_call_id: "q0"}]
        })

      expect(ServerAdapter.Mock, :resume, fn "agent-1", responses ->
        assert is_list(responses)
        assert length(responses) == 2
        :ok
      end)

      assert {:ok, _} =
               IntegrationHelpers.handle_question_response(socket, %{type: :answer, value: "now"})
    end
  end

  describe "reset_conversation/1" do
    test "resets all assigns to defaults when no conversation_id is set" do
      result =
        socket(%{streaming_delta: %{}, agent_status: :running, messages: [%{}]})
        |> IntegrationHelpers.reset_conversation()

      assert result.assigns.conversation == nil
      assert result.assigns.conversation_id == nil
      assert result.assigns.agent_status == :not_running
      assert result.assigns.streaming_delta == nil
      assert result.assigns.messages == []
    end
  end

  describe "load_conversation/3" do
    test "{:error, :not_found, socket} when the conversation does not exist" do
      scope = build_scope()
      missing_id = Ecto.UUID.generate()

      assert {:error, :not_found, _} =
               IntegrationHelpers.load_conversation(socket(), missing_id, scope: scope)
    end

    test "loads messages and sets agent assigns when found" do
      scope = build_scope()
      conversation = insert_conversation!(scope, %{title: "Loaded"})

      {:ok, _} =
        AgenticRuntime.Conversations.append_display_message(
          scope,
          conversation.id,
          text_message_attrs(%{content: %{"text" => "saved"}})
        )

      expect(ServerAdapter.Mock, :get_status, fn _ -> :idle end)

      assert {:ok, result} =
               IntegrationHelpers.load_conversation(socket(), conversation.id, scope: scope)

      assert result.assigns.conversation.id == conversation.id
      assert result.assigns.conversation_id == conversation.id
      assert result.assigns.agent_status == :idle
      assert result.assigns.has_messages == true
      assert length(result.assigns.messages) == 1
    end
  end

  describe "create_or_persist_message/3" do
    test "persists a text message when conversation_id and current_scope are set" do
      scope = build_scope()
      conversation = insert_conversation!(scope)

      socket =
        socket(%{
          conversation_id: conversation.id,
          current_scope: scope
        })

      msg = IntegrationHelpers.create_or_persist_message(socket, "user", "hi from test")
      assert msg.content["text"] == "hi from test"
      assert msg.message_type == "user"
    end

    test "creates an in-memory fallback when no scope is wired" do
      msg = IntegrationHelpers.create_or_persist_message(socket(), "user", "fallback")
      assert msg.content["text"] == "fallback"
      assert is_binary(msg.id)
    end
  end
end
