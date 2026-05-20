# Airline Customer Service Agents Demo

This is a Ruby port of the `openai-cs-agents-demo` airline customer service demo, implemented with this repository's `ai-agents` Ruby SDK.

It includes:

- Six airline support agents with SDK handoffs.
- Mock itinerary, flight status, seat, rebooking, FAQ, and compensation tools.
- A split-pane browser UI with an agent view, context state, runner events, customer chat, starter prompts, and an interactive seat map.
- No app-level guardrail or response-guideline implementation.

## Run

From the repository root:

```bash
export OPENAI_API_KEY=your_api_key
ruby cs-demo/server.rb
```

Then open:

```text
http://127.0.0.1:4567
```

You can choose a model with:

```bash
CS_DEMO_MODEL=gpt-5.2 ruby cs-demo/server.rb
```

## Demo Prompts

- `Can I change my seat?`
- `What's the status of flight FLT-123?`
- `My flight from Paris to New York was delayed and I missed my connection to Austin. I need to spend the night in New York. Can you help me?`
