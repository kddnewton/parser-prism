# frozen_string_literal: true

require "parser"
require "yarp"

require_relative "yarp/compiler"
require_relative "yarp/lexer"

module Parser
  module YARP
    # Parse the contents of the given buffer and return the AST.
    def self.parse(buffer)
      ::YARP.parse(buffer.source, buffer.name).value.accept(Compiler.new(buffer))
    end

    # Parse the contents of the given buffer and return the AST, tokens, and
    # comments.
    def self.tokenize(buffer)
      result = ::YARP.parse_lex(buffer.source, buffer.name)
      ast, lexed = result.value

      comments =
        result.comments.map do |comment|
          location = comment.location
          range = Source::Range.new(buffer, location.start_offset, location.end_offset)
          Source::Comment.new(range)
        end

      [ast.accept(Compiler.new(buffer)), comments, Lexer.new(buffer, lexed.map(&:first)).to_a]
    end
  end
end
