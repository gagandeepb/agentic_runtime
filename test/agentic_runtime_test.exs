defmodule AgenticRuntimeTest do
  use AgenticRuntime.AgentCase, async: true

  alias Sagents.Agent
  alias LangChain.ChatModels.{ChatAnthropic, ChatGoogleAI, ChatOpenAI}

  describe "building models" do
    test "builds ChatAnthropic model with stream + thinking enabled by default" do
      builder_fn_without_opts = fn model_name, api_key ->
        AgenticRuntime.build_anthropic_model_config(model_name, api_key)
      end

      builder_fn_with_empty_opts = fn model_name, api_key ->
        AgenticRuntime.build_anthropic_model_config(model_name, api_key, [])
      end

      for builder_fn <- [builder_fn_without_opts, builder_fn_with_empty_opts] do
        assert %ChatAnthropic{
                 model: "claude-opus-4-7",
                 api_key: "test-key",
                 stream: true,
                 thinking: %{type: "enabled"}
               } = builder_fn.("claude-opus-4-7", "test-key")
      end
    end

    test "builds ChatAnthropic model with :thinking opt override" do
      model =
        AgenticRuntime.build_anthropic_model_config("claude-opus-4-7", "k",
          thinking: %{type: "disabled"}
        )

      assert %ChatAnthropic{
               thinking: %{type: "disabled"}
             } = model
    end

    test "builds ChatOpenAI model with streaming enabled" do
      model = AgenticRuntime.build_openai_model_config("gpt-5", "test-key")

      assert %ChatOpenAI{
               model: "gpt-5",
               api_key: "test-key",
               stream: true
             } = model
    end

    test "builds ChatGoogleAI model with streaming enabled" do
      model = AgenticRuntime.build_googleai_model_config("gemini-2.0", "test-key")

      assert %ChatGoogleAI{
               model: "gemini-2.0",
               api_key: "test-key",
               stream: true
             } = model
    end
  end

  describe "create_agent/1" do
    setup do
      model = AgenticRuntime.build_anthropic_model_config("claude-opus-4-7", "test-key", [])
      {:ok, model: model}
    end

    test "returns {:ok, agent} with the full middleware stack composed", %{model: model} do
      assert {:ok,
              %Agent{
                agent_id: agent_id,
                middleware: middleware
              }} =
               AgenticRuntime.create_agent(
                 agent_id: "test-agent",
                 model_config: model,
                 base_system_prompt: "You are helpful."
               )

      assert agent_id == "test-agent"

      # DISABLED (plan: valiant-twirling-crown): FileSystem + AskUserQuestion removed from stack
      assert Enum.map(middleware, & &1.module) == [
               Sagents.Middleware.TodoList,
               Sagents.Middleware.ConversationTitle,
               # Sagents.Middleware.FileSystem,
               Sagents.Middleware.SubAgent,
               Sagents.Middleware.Summarization,
               Sagents.Middleware.PatchToolCalls
               # Sagents.Middleware.AskUserQuestion
             ]
    end

    test "raises on missing required :agent_id", %{model: model} do
      assert_raise KeyError, fn ->
        AgenticRuntime.create_agent(model_config: model, base_system_prompt: "x")
      end
    end

    test "raises on missing required :model_config" do
      assert_raise KeyError, fn ->
        AgenticRuntime.create_agent(agent_id: "x", base_system_prompt: "x")
      end
    end

    test "raises on missing required :base_system_prompt", %{model: model} do
      assert_raise KeyError, fn ->
        AgenticRuntime.create_agent(agent_id: "x", model_config: model)
      end
    end

    test "builds an Agent with the default options", %{model: model} do
      assert {:ok,
              %Agent{
                agent_id: "default-agent",
                scope: nil,
                tool_context: %{},
                fallback_models: [],
                before_fallback: nil
              }} =
               AgenticRuntime.create_agent(
                 agent_id: "default-agent",
                 model_config: model,
                 base_system_prompt: "x"
               )
    end

    test "builds an Agent with the provided options", %{model: model} do
      scope = %AgenticRuntime.Factory.Scope{owner_id: 99}
      tool_context = %{user_id: 99, tenant: "acme"}
      fallback = AgenticRuntime.build_openai_model_config("gpt-5", "k")
      before_fallback = fn chain -> chain end

      tool =
        AgenticRuntime.new_tool!(%{
          name: "echo",
          description: "echoes",
          function: fn _args, _ctx -> {:ok, "ok"} end
        })

      assert {:ok,
              %Agent{
                agent_id: "scoped-agent",
                scope: ^scope,
                tool_context: ^tool_context,
                fallback_models: [^fallback],
                before_fallback: ^before_fallback,
                tools: resolved_tools
              }} =
               AgenticRuntime.create_agent(
                 agent_id: "scoped-agent",
                 model_config: model,
                 base_system_prompt: "x",
                 scope: scope,
                 tool_context: tool_context,
                 tools: [tool],
                 fallback_models: [fallback],
                 before_fallback: before_fallback
               )

      # The Agent's `tools` list also contains middleware-injected tools
      # (TodoList, SubAgent, …); assert the caller-supplied tool is among them.
      assert "echo" in Enum.map(resolved_tools, & &1.name)
    end
  end

  describe "delegating to Langchain" do
    test "build_new_user_message!/1 returns a LangChain.Message with role :user and the supplied text" do
      msg = AgenticRuntime.build_new_user_message!("hello")
      assert %LangChain.Message{role: :user} = msg
      assert [%LangChain.Message.ContentPart{type: :text, content: "hello"}] = msg.content
    end

    test "new_tool!/1 returns a LangChain.Function with the given name" do
      tool =
        AgenticRuntime.new_tool!(%{
          name: "echo",
          description: "echoes",
          function: fn _args, _context -> {:ok, "ok"} end
        })

      assert %LangChain.Function{name: "echo"} = tool
    end
  end

  describe "add_message/2" do
    test "calls ServerAdapter.add_message/2 with the agent_id and message" do
      message = LangChain.Message.new_user!("hi")

      expect(ServerAdapter.Mock, :add_message, fn "agent-1", ^message -> :ok end)

      assert :ok = AgenticRuntime.add_message("agent-1", message)
    end
  end

  describe "cancel_agent_execution/1" do
    test "calls ServerAdapter.cancel/1 with the agent_id" do
      expect(ServerAdapter.Mock, :cancel, fn "agent-2" -> :ok end)
      assert :ok = AgenticRuntime.cancel_agent_execution("agent-2")
    end
  end

  describe "start_runtime/1" do
    test "delegates to SupervisorAdapter.child_spec/1" do
      expect(SupervisorAdapter.Mock, :child_spec, fn opts ->
        %{id: opts[:id], start: {__MODULE__, :noop, [opts]}}
      end)

      spec = AgenticRuntime.start_runtime(id: :test_runtime)
      assert spec.id == :test_runtime
    end
  end
end
