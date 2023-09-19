# frozen_string_literal: true

require "parser"
require "yarp"

module Parser
  class YARP < Base
    Racc_debug_parser = false

    def version
      33
    end

    def default_encoding
      Encoding::UTF_8
    end

    ##
    # Parses a source buffer and returns the AST.
    #
    # @param [Parser::Source::Buffer] source_buffer The source buffer to parse.
    # @return Parser::AST::Node
    #
    def parse(source_buffer)
      @source_buffer = source_buffer

      build_ast(::YARP.parse(source_buffer.source, source_buffer.name).value)
    ensure
      @source_buffer = nil
    end

    ##
    # Parses a source buffer and returns the AST and the source code comments.
    #
    # @see #parse
    # @see Parser::Source::Comment#associate
    # @return [Array]
    #
    def parse_with_comments(source_buffer)
      @source_buffer = source_buffer

      result = ::YARP.parse(source_buffer.source, source_buffer.name)
      [build_ast(result.value), build_comments(result.comments)]
    ensure
      @source_buffer = nil
    end

    ##
    # Parses a source buffer and returns the AST, the source code comments,
    # and the tokens emitted by the lexer.
    #
    # @param [Parser::Source::Buffer] source_buffer
    # @return [Array]
    #
    def tokenize(source_buffer, _recover = false)
      @source_buffer = source_buffer

      result = ::YARP.parse_lex(source_buffer.source, source_buffer.name)
      program, tokens = result.value

      [build_ast(program), build_comments(result.comments), build_tokens(tokens)]
    ensure
      @source_buffer = nil
    end

    # Since YARP resolves num params for us, we don't need to support this kind
    # of logic here.
    def try_declare_numparam(node)
      node.children[0].match?(/\A_[1-9]\z/)
    end

    private

    def build_ast(program)
      program.accept(Compiler.new(self))
    end

    def build_comments(comments)
      comments.map do |comment|
        location = comment.location
        range = Source::Range.new(source_buffer, location.start_offset, location.end_offset)
        Source::Comment.new(range)
      end
    end

    def build_tokens(tokens)
      Lexer.new(source_buffer, tokens.map(&:first)).to_a
    end
  end
end

require_relative "yarp/compiler"
require_relative "yarp/lexer"
