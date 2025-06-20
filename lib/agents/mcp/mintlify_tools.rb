# frozen_string_literal: true

require_relative 'client'

module Agents
  module MCP
    # Mintlify-specific MCP tools
    module MintlifyTools
      # Tool for searching Mintlify documentation
      class DocumentationSearchTool < Agents::ToolBase
        name "search_documentation"
        description "Search through Mintlify documentation content"
        param :query, "string", "Search query for documentation", required: true
        param :limit, "integer", "Maximum number of results", required: false

        def perform(query:, limit: 10, context: nil)
          mcp_client = get_mcp_client(context)
          
          result = mcp_client.call_tool("search_docs", {
            query: query,
            limit: limit
          })
          
          format_search_results(result)
        end

        private

        def get_mcp_client(context)
          client = context&.dig(:mcp_clients, :mintlify)
          raise MCPError, "Mintlify MCP client not available in context" unless client
          client
        end

        def format_search_results(result)
          return "No documentation found." if result.nil? || result.empty?
          
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
          
          formatted = "📚 Documentation Search Results:\n\n"
          
          results.each_with_index do |item, index|
            formatted += "#{index + 1}. **#{item['title'] || 'Untitled'}**\n"
            formatted += "   #{item['excerpt'] || item['content'] || 'No preview available'}\n"
            formatted += "   📄 #{item['url'] || item['path'] || 'No URL'}\n\n"
          end
          
          formatted
        end
      end

      # Tool for getting specific documentation pages
      class GetDocumentationTool < Agents::ToolBase
        name "get_documentation"
        description "Retrieve specific documentation page content"
        param :path, "string", "Documentation page path or URL", required: true

        def perform(path:, context: nil)
          mcp_client = get_mcp_client(context)
          
          result = mcp_client.call_tool("get_doc", { path: path })
          format_documentation(result)
        end

        private

        def get_mcp_client(context)
          client = context&.dig(:mcp_clients, :mintlify)
          raise MCPError, "Mintlify MCP client not available in context" unless client
          client
        end

        def format_documentation(result)
          return "Documentation not found." if result.nil? || result.empty?
          
          if result.is_a?(Hash)
            content = ""
            content += "# #{result['title']}\n\n" if result['title']
            content += result['content'] || result['body'] || ""
            content += "\n\n📄 Source: #{result['url'] || result['path']}" if result['url'] || result['path']
            content
          else
            result.to_s
          end
        end
      end

      # Tool for getting navigation structure
      class GetNavigationTool < Agents::ToolBase
        name "get_navigation"
        description "Get the documentation navigation structure"

        def perform(context: nil)
          mcp_client = get_mcp_client(context)
          
          result = mcp_client.call_tool("get_navigation", {})
          format_navigation(result)
        end

        private

        def get_mcp_client(context)
          client = context&.dig(:mcp_clients, :mintlify)
          raise MCPError, "Mintlify MCP client not available in context" unless client
          client
        end

        def format_navigation(result)
          return "Navigation not available." if result.nil? || result.empty?
          
          if result.is_a?(Hash) && result["navigation"]
            format_nav_tree(result["navigation"])
          elsif result.is_a?(Array)
            format_nav_tree(result)
          else
            result.to_s
          end
        end

        def format_nav_tree(nav_items, indent = 0)
          return "" unless nav_items.is_a?(Array)
          
          output = ""
          prefix = "  " * indent
          
          nav_items.each do |item|
            if item.is_a?(Hash)
              title = item['title'] || item['name'] || 'Untitled'
              output += "#{prefix}📁 #{title}\n"
              
              if item['children'] || item['pages']
                output += format_nav_tree(item['children'] || item['pages'], indent + 1)
              elsif item['path'] || item['url']
                output += "#{prefix}  📄 #{item['path'] || item['url']}\n"
              end
            else
              output += "#{prefix}📄 #{item}\n"
            end
          end
          
          output
        end
      end

      # Tool for checking documentation health/status
      class CheckDocumentationTool < Agents::ToolBase
        name "check_documentation"
        description "Check documentation health and get status information"

        def perform(context: nil)
          mcp_client = get_mcp_client(context)
          
          result = mcp_client.call_tool("health_check", {})
          format_health_status(result)
        end

        private

        def get_mcp_client(context)
          client = context&.dig(:mcp_clients, :mintlify)
          raise MCPError, "Mintlify MCP client not available in context" unless client
          client
        end

        def format_health_status(result)
          return "Health status unavailable." if result.nil? || result.empty?
          
          if result.is_a?(Hash)
            status = "📊 Documentation Health Status:\n\n"
            status += "✅ Status: #{result['status'] || 'Unknown'}\n"
            status += "📄 Total Pages: #{result['total_pages'] || 'Unknown'}\n"
            status += "🔗 Total Links: #{result['total_links'] || 'Unknown'}\n"
            status += "⚠️  Broken Links: #{result['broken_links'] || '0'}\n"
            status += "📅 Last Updated: #{result['last_updated'] || 'Unknown'}\n"
            status
          else
            result.to_s
          end
        end
      end
    end
  end
end