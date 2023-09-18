# frozen_string_literal: true

require "parser/current"

# First, opt in to every AST feature.
Parser::Builders::Default.modernize

# Modify the source map == check so that it doesn't check against the node
# itself so we don't get into a recursive loop.
Parser::Source::Map.prepend(
  Module.new {
    def ==(other)
      self.class == other.class &&
        (instance_variables - %i[@node]).map do |ivar|
          instance_variable_get(ivar) == other.instance_variable_get(ivar)
        end.reduce(:&)
    end
  }
)

# Next, ensure that we're comparing the nodes and also comparing the source
# ranges so that we're getting all of the necessary information.
Parser::AST::Node.prepend(
  Module.new {
    def ==(other)
      super && (location == other.location)
    end
  }
)

module Parser
  class YARP
    # Compare the ASTs between the translator and the whitequark/parser gem.
    def self.compare(filepath, source = nil, compare_tokens: true)
      buffer = Source::Buffer.new(filepath, 1)
      buffer.source = source || File.read(filepath)

      parser = CurrentRuby.default_parser
      parser.diagnostics.consumer = ->(*) {}
      parser.diagnostics.all_errors_are_fatal = true

      expected_ast, expected_comments, expected_tokens =
        begin
          parser.tokenize(buffer)
        rescue ArgumentError, SyntaxError
          return true
        end

      actual_ast, actual_comments, actual_tokens = YARP.new.tokenize(buffer)

      if expected_ast != actual_ast
        puts filepath
        queue = [[expected_ast, actual_ast]]

        while (left, right = queue.shift)
          if left.type != right.type
            puts "expected:"
            pp left

            puts "actual:"
            pp right

            return false
          end

          if left.location != right.location
            puts "expected:"
            pp left
            pp left.location

            puts "actual:"
            pp right
            pp right.location

            return false
          end

          left.children.zip(right.children).each do |left_child, right_child|
            queue << [left_child, right_child] if left_child.is_a?(Parser::AST::Node)
          end
        end

        return false
      end

      if compare_tokens && expected_tokens != actual_tokens
        expected_index = 0
        actual_index = 0

        while expected_index < expected_tokens.length
          expected_token = expected_tokens[expected_index]
          actual_token = actual_tokens[actual_index]

          expected_index += 1
          actual_index += 1

          if expected_token[0] == :tSPACE && actual_token[0] == :tSTRING_END
            expected_index += 1
            next
          end

          case actual_token[0]
          when :kDO
            actual_token[0] = expected_token[0] if %i[kDO_BLOCK kDO_LAMBDA].include?(expected_token[0])
          when :tLPAREN
            actual_token[0] = expected_token[0] if expected_token[0] == :tLPAREN2
          when :tLCURLY
            actual_token[0] = expected_token[0] if %i[tLBRACE tLBRACE_ARG].include?(expected_token[0])
          when :tPOW
            actual_token[0] = expected_token[0] if expected_token[0] == :tDSTAR
          end

          if expected_token != actual_token
            puts "expected:"
            pp expected_token

            puts "actual:"
            pp actual_token

            return false
          end
        end
      end

      if expected_comments != actual_comments
        puts "expected:"
        pp expected_comments

        puts "actual:"
        pp actual_comments

        return false
      end

      true
    end
  end
end
