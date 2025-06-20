# frozen_string_literal: true

module Agents
  module MCP
    # Dynamically created tool that wraps MCP server tools
    class DynamicTool < Agents::ToolBase
      attr_reader :mcp_tool_name, :mcp_client_key, :tool_schema

      def initialize(tool_schema, mcp_client_key)
        @tool_schema = tool_schema
        @mcp_tool_name = tool_schema["name"]
        @mcp_client_key = mcp_client_key
        @context = nil
        @tool_name = tool_schema["name"]
        @tool_description = tool_schema["description"]
        
        # Convert MCP schema to our parameter format
        setup_dynamic_parameters
      end

      def set_context(context)
        @context = context
      end

      # Call the tool with arguments (matches ToolBase interface)
      def call(**args)
        perform(**args)
      end

      def perform(**args)
        context = args.delete(:context) || @context
        mcp_client = get_mcp_client(context)
        
        result = mcp_client.call_tool(@mcp_tool_name, args)
        format_result(result)
      end

      def to_function_schema
        properties = {}
        required = []

        if @tool_parameters
          @tool_parameters.each do |param_name, param_config|
            properties[param_name] = {
              type: param_config[:type],
              description: param_config[:description]
            }
            required << param_name if param_config[:required]
          end
        end

        {
          type: "function",
          function: {
            name: @mcp_tool_name,
            description: @tool_description,
            parameters: {
              type: "object",
              properties: properties,
              required: required
            }
          }
        }
      end

      # Override instance methods to provide tool info
      def tool_name
        @tool_name
      end

      def tool_description  
        @tool_description
      end

      def tool_parameters
        @tool_parameters || {}
      end

      private

      def setup_dynamic_parameters
        return unless @tool_schema["inputSchema"] && @tool_schema["inputSchema"]["properties"]
        
        @tool_parameters = {}
        properties = @tool_schema["inputSchema"]["properties"]
        required_fields = @tool_schema["inputSchema"]["required"] || []
        
        properties.each do |param_name, param_def|
          @tool_parameters[param_name.to_sym] = {
            type: param_def["type"] || "string",
            description: param_def["description"] || param_name.to_s.tr("_", " ").capitalize,
            required: required_fields.include?(param_name)
          }
        end
      end

      def get_mcp_client(context)
        client = context&.dig(:mcp_clients, @mcp_client_key)
        raise MCPError, "MCP client '#{@mcp_client_key}' not available in context" unless client
        client
      end

      def format_result(result)
        case result
        when Hash
          format_hash_result(result)
        when Array
          result.map(&:to_s).join("\n")
        when String
          result
        else
          result.to_s
        end
      end

      def format_hash_result(result)
        case @mcp_tool_name
        when "search_docs"
          format_documentation_search(result)
        when "web_search"
          format_web_search(result)
        when "news_search"
          format_news_search(result)
        when "get_doc"
          format_documentation_page(result)
        when "get_navigation"
          format_navigation(result)
        else
          # Generic formatting
          if result["results"] || result["articles"]
            format_generic_results(result)
          else
            result.to_s
          end
        end
      end

      def format_documentation_search(result)
        return "No documentation found." unless result["results"]
        
        formatted = "📚 Documentation Search Results:\n\n"
        result["results"].each_with_index do |item, index|
          formatted += "#{index + 1}. **#{item['title'] || 'Untitled'}**\n"
          formatted += "   #{item['excerpt'] || item['content'] || 'No preview available'}\n"
          formatted += "   📄 #{item['url'] || item['path'] || 'No URL'}\n\n"
        end
        formatted
      end

      def format_web_search(result)
        return "No search results found." unless result["results"]
        
        formatted = "🌐 Web Search Results:\n\n"
        result["results"].each_with_index do |item, index|
          formatted += "#{index + 1}. **#{item['title'] || 'Untitled'}**\n"
          formatted += "   #{item['snippet'] || item['description'] || 'No description available'}\n"
          formatted += "   🔗 #{item['url'] || item['link'] || 'No URL'}\n\n"
        end
        formatted
      end

      def format_news_search(result)
        return "No news found." unless result["articles"]
        
        formatted = "📰 Recent News:\n\n"
        result["articles"].each_with_index do |article, index|
          formatted += "#{index + 1}. **#{article['title'] || 'Untitled'}**\n"
          formatted += "   #{article['summary'] || article['description'] || 'No summary available'}\n"
          formatted += "   📅 #{article['published_date'] || 'Date unknown'}\n"
          formatted += "   🔗 #{article['url'] || 'No URL'}\n\n"
        end
        formatted
      end

      def format_documentation_page(result)
        return "Documentation not found." unless result["found"]
        
        content = "# #{result['title']}\n\n" if result['title']
        content += result['content'] || ""
        content += "\n\n📄 Source: #{result['url'] || result['path']}" if result['url'] || result['path']
        content
      end

      def format_navigation(result)
        return "Navigation not available." unless result["navigation"]
        
        formatted = "📋 Documentation Structure:\n\n"
        formatted += format_nav_tree(result["navigation"])
        formatted += "\n📄 Total pages: #{result['total_pages']}" if result['total_pages']
        formatted
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

      def format_generic_results(result)
        if result["results"]
          items = result["results"]
          formatted = "🔍 Search Results:\n\n"
        elsif result["articles"]
          items = result["articles"]
          formatted = "📰 Articles:\n\n"
        else
          return result.to_s
        end
        
        items.each_with_index do |item, index|
          formatted += "#{index + 1}. #{item['title'] || item['name'] || 'Item'}\n"
          formatted += "   #{item['description'] || item['content'] || item['summary'] || 'No description'}\n\n"
        end
        
        formatted
      end
    end
  end
end