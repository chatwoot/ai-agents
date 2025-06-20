# frozen_string_literal: true

require_relative 'client'

module Agents
  module MCP
    # WebSearch-specific MCP tools
    module WebSearchTools
      # Tool for searching the web
      class WebSearchTool < Agents::ToolBase
        name "web_search"
        description "Search the web for current information"
        param :query, "string", "Search query", required: true
        param :num_results, "integer", "Number of results to return", required: false

        def perform(query:, num_results: 5, context: nil)
          mcp_client = get_mcp_client(context)
          
          result = mcp_client.call_tool("web_search", {
            query: query,
            num_results: num_results
          })
          
          format_search_results(result)
        end

        private

        def get_mcp_client(context)
          client = context&.dig(:mcp_clients, :websearch)
          raise MCPError, "WebSearch MCP client not available in context" unless client
          client
        end

        def format_search_results(result)
          return "No search results found." if result.nil? || result.empty?
          
          if result.is_a?(String)
            result
          elsif result.is_a?(Hash) && result["results"]
            format_structured_results(result["results"])
          else
            result.to_s
          end
        end

        def format_structured_results(results)
          return "No results found." if results.empty?
          
          formatted = "🌐 Web Search Results:\n\n"
          
          results.each_with_index do |item, index|
            formatted += "#{index + 1}. **#{item['title'] || 'Untitled'}**\n"
            formatted += "   #{item['snippet'] || item['description'] || 'No description available'}\n"
            formatted += "   🔗 #{item['url'] || item['link'] || 'No URL'}\n\n"
          end
          
          formatted
        end
      end

      # Tool for getting news updates
      class NewsSearchTool < Agents::ToolBase
        name "news_search"
        description "Search for recent news articles"
        param :topic, "string", "News topic to search for", required: true
        param :days, "integer", "Number of days back to search", required: false

        def perform(topic:, days: 7, context: nil)
          mcp_client = get_mcp_client(context)
          
          result = mcp_client.call_tool("news_search", {
            topic: topic,
            days: days
          })
          
          format_news_results(result)
        end

        private

        def get_mcp_client(context)
          client = context&.dig(:mcp_clients, :websearch)
          raise MCPError, "WebSearch MCP client not available in context" unless client
          client
        end

        def format_news_results(result)
          return "No news found." if result.nil? || result.empty?
          
          if result.is_a?(String)
            result
          elsif result.is_a?(Hash) && result["articles"]
            format_news_articles(result["articles"])
          else
            result.to_s
          end
        end

        def format_news_articles(articles)
          return "No news articles found." if articles.empty?
          
          formatted = "📰 Recent News:\n\n"
          
          articles.each_with_index do |article, index|
            formatted += "#{index + 1}. **#{article['title'] || 'Untitled'}**\n"
            formatted += "   #{article['summary'] || article['description'] || 'No summary available'}\n"
            formatted += "   📅 #{article['published_date'] || 'Date unknown'}\n"
            formatted += "   🔗 #{article['url'] || 'No URL'}\n\n"
          end
          
          formatted
        end
      end
    end
  end
end