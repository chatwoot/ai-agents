.PHONY: smoke-all

smoke-all:
	RUN_LIVE_LLM=true LIVE_LLM_PROVIDER=openai bundle exec rspec --tag live_llm
	RUN_LIVE_LLM=true LIVE_LLM_PROVIDER=anthropic bundle exec rspec --tag live_llm
	RUN_LIVE_LLM=true LIVE_LLM_PROVIDER=gemini bundle exec rspec --tag live_llm
