defmodule AgenticRuntime.Agents.FactoryTest do
  use ExUnit.Case, async: true

  alias AgenticRuntime.Agents.Factory

  defp build_model do
    AgenticRuntime.build_anthropic_model_config("claude-opus-4-7", "test-key", [])
  end

  describe "create_agent/1" do
    test "produces an agent whose middleware stack matches the documented order" do
      assert {:ok, agent} =
               Factory.create_agent(
                 agent_id: "factory-test",
                 model_config: build_model(),
                 base_system_prompt: "Be helpful."
               )

      modules = Enum.map(agent.middleware, & &1.module)

      # DISABLED (plan: valiant-twirling-crown): FileSystem + AskUserQuestion removed from stack
      expected = [
        Sagents.Middleware.TodoList,
        Sagents.Middleware.ConversationTitle,
        # Sagents.Middleware.FileSystem,
        Sagents.Middleware.SubAgent,
        Sagents.Middleware.Summarization,
        Sagents.Middleware.PatchToolCalls
        # Sagents.Middleware.AskUserQuestion
      ]

      assert modules == expected
    end

    # DISABLED (plan: valiant-twirling-crown): HumanInTheLoop append removed from factory
    # test "appends HumanInTheLoop when :interrupt_on is provided" do
    #   assert {:ok, agent} =
    #            Factory.create_agent(
    #              agent_id: "factory-hitl",
    #              model_config: build_model(),
    #              base_system_prompt: "x",
    #              interrupt_on: %{"delete_file" => true}
    #            )

    #   modules = Enum.map(agent.middleware, & &1.module)
    #   assert Sagents.Middleware.HumanInTheLoop in modules
    # end

    test "does not append HumanInTheLoop when :interrupt_on is nil" do
      assert {:ok, agent} =
               Factory.create_agent(
                 agent_id: "factory-no-hitl",
                 model_config: build_model(),
                 base_system_prompt: "x"
               )

      modules = Enum.map(agent.middleware, & &1.module)
      refute Sagents.Middleware.HumanInTheLoop in modules
    end

    test "passes :tool_context through to the agent struct" do
      ctx = %{user_id: 42, tenant: "acme"}

      assert {:ok, agent} =
               Factory.create_agent(
                 agent_id: "factory-ctx",
                 model_config: build_model(),
                 base_system_prompt: "x",
                 tool_context: ctx
               )

      assert agent.tool_context == ctx
    end

    test "raises KeyError when :agent_id is missing" do
      assert_raise KeyError, fn ->
        Factory.create_agent(model_config: build_model(), base_system_prompt: "x")
      end
    end

    test "raises KeyError when :model_config is missing" do
      assert_raise KeyError, fn ->
        Factory.create_agent(agent_id: "x", base_system_prompt: "x")
      end
    end

    test "raises KeyError when :base_system_prompt is missing" do
      assert_raise KeyError, fn ->
        Factory.create_agent(agent_id: "x", model_config: build_model())
      end
    end
  end

  describe "create_agent/1 — option pass-through" do
    test "passes :fallback_models through to the agent struct" do
      fallback = AgenticRuntime.build_openai_model_config("gpt-5", "k")

      assert {:ok, agent} =
               Factory.create_agent(
                 agent_id: "factory-fb",
                 model_config: build_model(),
                 base_system_prompt: "x",
                 fallback_models: [fallback]
               )

      assert agent.fallback_models == [fallback]
    end

    test "passes :before_fallback through to the agent struct" do
      cb = fn chain -> chain end

      assert {:ok, agent} =
               Factory.create_agent(
                 agent_id: "factory-bf",
                 model_config: build_model(),
                 base_system_prompt: "x",
                 before_fallback: cb
               )

      assert agent.before_fallback == cb
    end

    test ":title_model_config defaults to :model_config when omitted" do
      # The title-generation middleware should fall back to the main model config
      # when no separate one is given. Inspect the ConversationTitle middleware
      # opts to confirm the model carried into the stack is the main model.
      main = build_model()

      {:ok, agent} =
        Factory.create_agent(
          agent_id: "factory-title-default",
          model_config: main,
          base_system_prompt: "x"
        )

      title_entry =
        Enum.find(agent.middleware, &match?(%{module: Sagents.Middleware.ConversationTitle}, &1))

      assert title_entry
      assert title_entry.config.chat_model == main
    end

    test ":title_model_config overrides the title middleware's chat_model" do
      title = AgenticRuntime.build_openai_model_config("gpt-5", "k")

      {:ok, agent} =
        Factory.create_agent(
          agent_id: "factory-title-override",
          model_config: build_model(),
          base_system_prompt: "x",
          title_model_config: title
        )

      title_entry =
        Enum.find(agent.middleware, &match?(%{module: Sagents.Middleware.ConversationTitle}, &1))

      assert title_entry.config.chat_model == title
    end

    test ":tool_context defaults to %{} when not provided" do
      {:ok, agent} =
        Factory.create_agent(
          agent_id: "factory-default-ctx",
          model_config: build_model(),
          base_system_prompt: "x"
        )

      assert agent.tool_context == %{}
    end
  end

  describe "model config builders" do
    test "build_anthropic_model_config sets model, key, stream, and thinking" do
      m = Factory.build_anthropic_model_config("claude-opus-4-7", "k", [])
      assert m.model == "claude-opus-4-7"
      assert m.api_key == "k"
      assert m.stream == true
      assert m.thinking == %{type: "enabled"}
    end

    test "build_openai_model_config sets model, key, and stream" do
      m = Factory.build_openai_model_config("gpt-5", "k")
      assert m.model == "gpt-5"
      assert m.api_key == "k"
      assert m.stream == true
    end

    test "build_googleai_model_config sets model, key, and stream" do
      m = Factory.build_googleai_model_config("gemini-2", "k")
      assert m.model == "gemini-2"
      assert m.api_key == "k"
      assert m.stream == true
    end
  end
end
